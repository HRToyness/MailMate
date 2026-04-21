import AppKit
import Combine
import UserNotifications

@MainActor
final class ReplyDrafter {
    static let shared = ReplyDrafter()

    private let panel = VariantPanel()
    private var variantTask: Task<Void, Never>?

    private var dictationPanel: DictationPanel?
    private var dictationRecorder: AudioRecorder?
    private var dictationEmail: MailMessage?
    private var dictationStreamTask: Task<Void, Never>?
    private var dictationCleanupDone = false
    private var recorderObservers: Set<AnyCancellable> = []

    // MARK: - Notifications

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.write("notification auth error: \(error.localizedDescription)")
            } else {
                Log.write("notification auth granted=\(granted)")
            }
        }
    }

    // MARK: - Variant flow

    func run() async {
        Log.write("=== run() start ===")
        let kind = ProviderFactory.current
        Log.write("Active provider: \(kind.rawValue)")

        let client: ReplyProvider
        do {
            client = try ProviderFactory.make(kind)
        } catch let ProviderError.missingAPIKey(k) {
            notify("Set your \(k.displayName) API key in Settings.")
            return
        } catch {
            notify("Error: \(error.localizedDescription)")
            return
        }

        let email: MailMessage
        do {
            email = try MailBridge.getSelectedMessage()
        } catch MailBridgeError.noSelection {
            notify("Select a message in Mail first.")
            return
        } catch {
            notify("Error: \(error.localizedDescription)")
            return
        }
        Log.write("Got message: sender='\(email.sender)' subject='\(email.subject)' body.len=\(email.body.count)")

        let rules = RulesLoader.load()
        Log.write("Rules loaded (len=\(rules.count))")

        let state = VariantStreamState()
        variantTask?.cancel()
        panel.show(
            state: state,
            onPick: { [weak self] chosen in self?.handlePick(chosen) },
            onClose: { [weak self] in
                Log.write("Variant panel closed before pick — cancelling stream")
                self?.variantTask?.cancel()
            }
        )

        variantTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let final = try await client.streamVariants(email: email, rules: rules) { accumulated in
                    if Task.isCancelled { return }
                    state.variants = VariantParser.parse(accumulated)
                }
                if Task.isCancelled { return }
                state.isStreaming = false
                Log.write("Variants: short=\(state.variants.short.count) standard=\(state.variants.standard.count) detailed=\(state.variants.detailed.count)")

                if state.variants.nonEmpty.isEmpty {
                    Log.write("Empty reply after stream. Raw len=\(final.count)")
                    state.errorMessage = "Model returned empty reply."
                    self.notify("Model returned empty reply. See ~/Library/Logs/MailMate.log")
                }
            } catch is CancellationError {
                Log.write("Variant stream cancelled")
            } catch {
                Log.write("ERROR: \(error.localizedDescription)")
                state.isStreaming = false
                state.errorMessage = error.localizedDescription
                self.notify("Error: \(error.localizedDescription)")
            }
            self.variantTask = nil
        }
    }

    // MARK: - Dictation flow

    func runDictation() async {
        Log.write("=== runDictation() start ===")

        // Whisper always needs an OpenAI key regardless of the active LLM.
        guard let openaiKey = KeychainHelper.load(for: .openai), !openaiKey.isEmpty else {
            Log.write("missing OpenAI key for Whisper")
            notify("Set your OpenAI API key in Settings (required for voice dictation).")
            return
        }
        _ = openaiKey // silences the unused-let warning; used via WhisperClient.make().

        let kind = ProviderFactory.current
        let client: ReplyProvider
        do {
            client = try ProviderFactory.make(kind)
        } catch let ProviderError.missingAPIKey(k) {
            notify("Set your \(k.displayName) API key in Settings.")
            return
        } catch {
            notify("Error: \(error.localizedDescription)")
            return
        }

        let email: MailMessage
        do {
            email = try MailBridge.getSelectedMessage()
        } catch MailBridgeError.noSelection {
            notify("Select a message in Mail first.")
            return
        } catch {
            notify("Error: \(error.localizedDescription)")
            return
        }
        dictationEmail = email
        Log.write("Dictation target: sender='\(email.sender)' subject='\(email.subject)' body.len=\(email.body.count)")

        let granted = await AudioRecorder.ensurePermission()
        guard granted else {
            promptForMicrophone()
            dictationEmail = nil
            return
        }

        // Fresh panel and recorder.
        dictationCleanupDone = false
        let panel = DictationPanel()
        self.dictationPanel = panel
        let recorder = AudioRecorder()
        self.dictationRecorder = recorder
        bindRecorder(recorder, to: panel.state)

        panel.state.onStart = { [weak self] in self?.dictationStart() }
        panel.state.onStop = { [weak self] in
            Task { @MainActor in await self?.dictationStopAndProcess(client: client) }
        }
        panel.state.onUse = { [weak self] in self?.dictationUse() }
        panel.state.onRerecord = { [weak self] in self?.dictationRerecord() }
        panel.state.onCancel = { [weak self] in self?.dictationCancel() }

        panel.show()
    }

    private func bindRecorder(_ recorder: AudioRecorder, to state: DictationState) {
        recorderObservers.removeAll()
        recorder.$level.sink { [weak state] in state?.level = $0 }.store(in: &recorderObservers)
        recorder.$elapsed.sink { [weak state] in state?.elapsed = $0 }.store(in: &recorderObservers)
    }

    private func dictationStart() {
        guard let recorder = dictationRecorder, let state = dictationPanel?.state else { return }
        do {
            try recorder.start()
            state.phase = .recording
        } catch {
            Log.write("recorder start error: \(error.localizedDescription)")
            state.phase = .error(error.localizedDescription)
        }
    }

    private func dictationStopAndProcess(client: ReplyProvider) async {
        guard let recorder = dictationRecorder,
              let panel = dictationPanel,
              let email = dictationEmail else { return }
        let state = panel.state

        // Idempotent: if we're not currently recording, nothing to do.
        guard case .recording = state.phase else { return }

        guard let url = recorder.stop() else {
            state.phase = .error("No recording captured.")
            return
        }
        // Guarantee the temp file is removed on every exit path.
        defer { try? FileManager.default.removeItem(at: url) }

        state.phase = .transcribing

        let whisper: WhisperClient
        do {
            whisper = try WhisperClient.make()
        } catch {
            state.phase = .error(error.localizedDescription)
            return
        }

        let transcript: String
        do {
            transcript = try await whisper.transcribe(audioURL: url)
        } catch {
            Log.write("whisper error: \(error.localizedDescription)")
            state.phase = .error(error.localizedDescription)
            return
        }
        state.transcript = transcript

        if transcript.isEmpty {
            state.phase = .error("No speech detected.")
            return
        }

        state.phase = .generating
        let rules = RulesLoader.load()

        dictationStreamTask?.cancel()
        dictationStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await client.streamDictatedReply(
                    transcript: transcript,
                    email: email,
                    rules: rules
                ) { accumulated in
                    if Task.isCancelled { return }
                    state.reply = accumulated
                }
                if Task.isCancelled { return }
                if state.reply.isEmpty {
                    state.phase = .error("Model returned empty reply.")
                } else {
                    state.phase = .ready
                }
            } catch is CancellationError {
                Log.write("Dictation stream cancelled")
            } catch {
                Log.write("dictation stream error: \(error.localizedDescription)")
                state.phase = .error(error.localizedDescription)
            }
            self.dictationStreamTask = nil
        }
    }

    private func dictationUse() {
        guard let panel = dictationPanel else { return }
        let text = panel.state.reply
        Log.write("Dictation: user picked reply (len=\(text.count))")
        cleanupDictation(closeWindow: true)
        do {
            try MailBridge.pasteIntoReply(text: text)
            Log.write("Dictation paste completed")
        } catch let MailBridgeError.scriptError(msg) where msg.contains("not allowed to send keystrokes") {
            promptForAccessibility()
        } catch MailBridgeError.noSelection {
            notify("The selected message is no longer available.")
        } catch {
            Log.write("Dictation paste error: \(error.localizedDescription)")
            notify("Error: \(error.localizedDescription)")
        }
    }

    private func dictationRerecord() {
        guard let panel = dictationPanel else { return }
        dictationStreamTask?.cancel()
        dictationStreamTask = nil
        panel.state.transcript = ""
        panel.state.reply = ""
        panel.state.phase = .idle
        dictationRecorder?.cancel()
        let fresh = AudioRecorder()
        dictationRecorder = fresh
        bindRecorder(fresh, to: panel.state)
    }

    private func dictationCancel() {
        cleanupDictation(closeWindow: true)
    }

    private func cleanupDictation(closeWindow: Bool) {
        if dictationCleanupDone { return }
        dictationCleanupDone = true
        dictationStreamTask?.cancel()
        dictationStreamTask = nil
        dictationRecorder?.cancel()
        dictationRecorder = nil
        recorderObservers.removeAll()
        dictationEmail = nil
        if closeWindow {
            dictationPanel?.close()
        }
        dictationPanel = nil
    }

    // MARK: - Variant pick handler

    private func handlePick(_ text: String) {
        Log.write("User picked variant (len=\(text.count))")
        do {
            try MailBridge.pasteIntoReply(text: text)
            Log.write("Paste into reply completed")
        } catch MailBridgeError.noSelection {
            notify("The selected message is no longer available.")
        } catch let MailBridgeError.scriptError(msg) where msg.contains("not allowed to send keystrokes") {
            Log.write("Accessibility permission missing — prompting user")
            promptForAccessibility()
        } catch {
            Log.write("Paste ERROR: \(error.localizedDescription)")
            notify("Error: \(error.localizedDescription)")
        }
    }

    // MARK: - Permission prompts

    private func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
        MailMate needs Accessibility permission to paste the reply into Mail.

        The reply is already on your clipboard — you can paste it manually with ⌘V.

        To fix this for future replies: open System Settings → Privacy & Security → Accessibility, then enable MailMate.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func promptForMicrophone() {
        let alert = NSAlert()
        alert.messageText = "Microphone access needed"
        alert.informativeText = """
        MailMate needs microphone access to dictate replies.

        Open System Settings → Privacy & Security → Microphone and enable MailMate.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "MailMate"
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
