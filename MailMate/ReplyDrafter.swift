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
    private var dictationPriorThread: [MailMessage] = []
    private var dictationStreamTask: Task<Void, Never>?
    private var dictationCleanupDone = false
    private var recorderObservers: Set<AnyCancellable> = []

    /// Reads the selected message, optionally including prior thread context
    /// when the `include_thread` pref is on. Falls back to a single-message
    /// fetch if the thread-aware AppleScript fails.
    private static func fetchMessageAndOptionalThread() throws -> (MailMessage, [MailMessage]) {
        if UserDefaults.standard.bool(forKey: "include_thread") {
            do {
                let result = try MailBridge.getSelectedMessageWithThread(maxPrior: 8)
                return (result.selected, result.prior)
            } catch MailBridgeError.noSelection {
                throw MailBridgeError.noSelection
            } catch {
                Log.write("Thread fetch failed, falling back: \(error.localizedDescription)")
            }
        }
        return (try MailBridge.getSelectedMessage(), [])
    }

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
        let priorThread: [MailMessage]
        do {
            let (sel, prior) = try Self.fetchMessageAndOptionalThread()
            email = sel
            priorThread = prior
        } catch MailBridgeError.noSelection {
            notify("Select a message in Mail first.")
            return
        } catch {
            notify("Error: \(error.localizedDescription)")
            return
        }
        Log.write("Got message: sender='\(email.sender)' subject='\(email.subject)' body.len=\(email.body.count) prior=\(priorThread.count)")

        let rules = RulesLoader.rules(for: email.sender)
        Log.write("Rules resolved for sender (len=\(rules.count))")

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
                let final = try await client.streamVariants(email: email, priorThread: priorThread, rules: rules) { accumulated in
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
        let priorThread: [MailMessage]
        do {
            let (sel, prior) = try Self.fetchMessageAndOptionalThread()
            email = sel
            priorThread = prior
        } catch MailBridgeError.noSelection {
            notify("Select a message in Mail first.")
            return
        } catch {
            notify("Error: \(error.localizedDescription)")
            return
        }
        dictationEmail = email
        dictationPriorThread = priorThread
        Log.write("Dictation target: sender='\(email.sender)' subject='\(email.subject)' body.len=\(email.body.count) prior=\(priorThread.count)")

        let granted = await AudioRecorder.ensurePermission()
        guard granted else {
            promptForMicrophone()
            dictationEmail = nil
            dictationPriorThread = []
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
        let priorThread = dictationPriorThread

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
        let rules = RulesLoader.rules(for: email.sender)

        dictationStreamTask?.cancel()
        dictationStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await client.streamDictatedReply(
                    transcript: transcript,
                    email: email,
                    priorThread: priorThread,
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
        dictationPriorThread = []
        if closeWindow {
            dictationPanel?.close()
        }
        dictationPanel = nil
    }

    // MARK: - Summary flow

    private let summaryPanel = SummaryPanel()
    private var summaryTask: Task<Void, Never>?

    func runSummary() async {
        Log.write("=== runSummary() start ===")
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
        let priorThread: [MailMessage]
        do {
            // Force-enable thread for summaries so the summary has context
            // even when the user doesn't have include_thread on globally.
            let result = try MailBridge.getSelectedMessageWithThread(maxPrior: 10)
            email = result.selected
            priorThread = result.prior
        } catch MailBridgeError.noSelection {
            notify("Select a message in Mail first.")
            return
        } catch {
            // Fallback to single-message fetch.
            do {
                email = try MailBridge.getSelectedMessage()
                priorThread = []
            } catch MailBridgeError.noSelection {
                notify("Select a message in Mail first.")
                return
            } catch {
                notify("Error: \(error.localizedDescription)")
                return
            }
        }
        Log.write("Summary target: sender='\(email.sender)' subject='\(email.subject)' prior=\(priorThread.count)")

        let state = SummaryState()
        summaryTask?.cancel()
        summaryPanel.show(state: state) { [weak self] in
            self?.summaryTask?.cancel()
        }

        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await client.streamSummary(email: email, priorThread: priorThread) { accumulated in
                    if Task.isCancelled { return }
                    state.text = accumulated
                }
                if Task.isCancelled { return }
                state.isStreaming = false
            } catch is CancellationError {
                Log.write("Summary stream cancelled")
            } catch {
                Log.write("Summary error: \(error.localizedDescription)")
                state.isStreaming = false
                state.errorMessage = error.localizedDescription
                self.notify("Error: \(error.localizedDescription)")
            }
            self.summaryTask = nil
        }
    }

    // MARK: - Rules proposal flow

    private let rulesProposalPanel = RulesProposalPanel()
    private var rulesProposalTask: Task<Void, Never>?

    func runRulesProposal() async {
        Log.write("=== runRulesProposal() start ===")
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

        rulesProposalPanel.state.phase = .loading
        rulesProposalPanel.state.proposedRules = ""
        rulesProposalPanel.state.scannedCount = 0
        rulesProposalPanel.state.saveError = nil
        rulesProposalPanel.state.savedFlash = nil
        rulesProposalPanel.state.onClose = { [weak self] in
            self?.rulesProposalTask?.cancel()
            self?.rulesProposalPanel.close()
        }
        rulesProposalPanel.state.onCopy = { [weak self] in
            self?.rulesProposalCopy()
        }
        rulesProposalPanel.state.onReplace = { [weak self] in
            self?.rulesProposalReplace()
        }
        rulesProposalPanel.show()

        rulesProposalTask?.cancel()
        rulesProposalTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sent = try MailBridge.fetchSentMessages(maxCount: 25)
                self.rulesProposalPanel.state.scannedCount = sent.count
                if sent.isEmpty {
                    self.rulesProposalPanel.state.phase = .error("No sent messages found. Try again after you've sent a few emails.")
                    return
                }

                let system = """
                You are inferring a user's personal writing style from their outgoing email. You will get the SUBJECT + BODY of their last \(sent.count) sent messages. Produce a rules.md file in the format shown below.

                Guidelines:
                - Output VALID markdown only. No code fences, no preamble, no commentary before or after the markdown.
                - Detect the dominant language(s). If the user writes in Dutch AND English, note both.
                - Extract observable patterns ONLY: tone (formal vs informal, "je" vs "u"), greeting/closing preferences, typical length, how they handle commitments (do they commit to dates/prices directly, or do they hedge?), whether they use a signature, whether they tend to ask questions, etc.
                - Do NOT invent rules that have no evidence in the messages.
                - Keep it concise — 30 lines max. Short bullet points.

                Required structure:
                # MailMate Rules

                ## Who I am
                - (what you can infer about role / sectors / clients, or a best guess, or omit if none)

                ## Tone
                - (observations about formality, greeting style, use of first names, etc.)

                ## Language
                - (which language(s) they write in, any notable mixed use)

                ## Never
                - (things they clearly avoid — e.g. "Never commit to specific dates without flagging [CONFIRM]" if you see that pattern)

                ## Prefer
                - (length preference, question-answering style, paragraph structure, etc.)

                ## Signature
                - (state whether Mail.app handles signature; say "Do not write a signature. Mail.app appends mine automatically." unless they clearly type signatures themselves)
                """

                let user = sent.enumerated().map { idx, m in
                    "### Sent message \(idx + 1)\nDate: \(m.dateSent)\nSubject: \(m.subject)\n\n\(m.body)"
                }.joined(separator: "\n\n")

                let raw = try await client.oneShot(system: system, user: user)
                if Task.isCancelled { return }

                // Strip ```markdown fences if the model added them despite the instruction.
                var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.hasPrefix("```") {
                    if let nl = cleaned.firstIndex(of: "\n") {
                        cleaned = String(cleaned[cleaned.index(after: nl)...])
                    }
                    if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                self.rulesProposalPanel.state.proposedRules = cleaned
                self.rulesProposalPanel.state.phase = .ready
                Log.write("Rules proposal ready: \(cleaned.count) chars from \(sent.count) sent messages")
            } catch is CancellationError {
                Log.write("Rules proposal cancelled")
            } catch {
                Log.write("Rules proposal error: \(error.localizedDescription)")
                self.rulesProposalPanel.state.phase = .error(error.localizedDescription)
            }
            self.rulesProposalTask = nil
        }
    }

    private func rulesProposalCopy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(rulesProposalPanel.state.proposedRules, forType: .string)
        rulesProposalPanel.state.savedFlash = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.rulesProposalPanel.state.savedFlash == "Copied" {
                self?.rulesProposalPanel.state.savedFlash = nil
            }
        }
    }

    private func rulesProposalReplace() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Replace your current rules?", comment: "")
        alert.informativeText = NSLocalizedString("This overwrites the rules file at ~/Library/Application Support/MailMate/rules.md with the proposed rules. Your current rules will be lost.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Replace", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        do {
            try rulesProposalPanel.state.proposedRules.write(
                to: RulesLoader.rulesFileURL,
                atomically: true,
                encoding: .utf8
            )
            rulesProposalPanel.state.saveError = nil
            rulesProposalPanel.state.savedFlash = "Saved"
            Log.write("Rules replaced from proposal (len=\(rulesProposalPanel.state.proposedRules.count))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                if self?.rulesProposalPanel.state.savedFlash == "Saved" {
                    self?.rulesProposalPanel.state.savedFlash = nil
                }
            }
        } catch {
            rulesProposalPanel.state.saveError = "Save failed: \(error.localizedDescription)"
            Log.write("Rules save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Inbox triage flow

    private let triagePanel = TriagePanel()
    private var triageTask: Task<Void, Never>?

    func runTriage() async {
        Log.write("=== runTriage() start ===")
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

        // Show panel immediately in loading state.
        triagePanel.state.phase = .loading
        triagePanel.state.entries = []
        triagePanel.state.sourceCount = 0
        triagePanel.state.onRefresh = { [weak self] in
            Task { @MainActor in await self?.runTriage() }
        }
        triagePanel.state.onSelect = { [weak self] entry in
            self?.triageSelect(entry)
        }
        triagePanel.state.onClose = { [weak self] in
            self?.triageTask?.cancel()
            self?.triagePanel.close()
        }
        triagePanel.show()

        triageTask?.cancel()
        triageTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let messages = try MailBridge.fetchRecentUnread(maxCount: 20)
                self.triagePanel.state.sourceCount = messages.count
                if messages.isEmpty {
                    self.triagePanel.state.phase = .ready
                    return
                }

                let userPrompt = messages.map { m in
                    "### Message \(m.index)\nFrom: \(m.sender)\nSubject: \(m.subject)\nDate: \(m.dateReceived)\n\n\(m.snippet)"
                }.joined(separator: "\n\n")

                let rules = RulesLoader.load()
                let system = """
                You are triaging the unread inbox of a specific user. Their rules file tells you who they are, what they work on, and which senders matter. Use that context when assigning priority — e.g. a request from a sector the user works in is likely more important than a generic one.

                ## User's rules (for context about who they are)
                \(rules)

                ## Output
                Return ONE valid JSON array, no code fences, no preamble, no commentary. Each element:
                - "index": integer (message number as given)
                - "priority": "urgent" | "normal" | "low" | "spam"
                - "summary": one sentence, under 20 words, in the SAME LANGUAGE as the message
                - "action": short phrase like "reply", "read", "archive", "schedule meeting", "delegate", "none"

                Sort the array most-important first. Skip obvious newsletters/promotions unless they're genuinely urgent. Do not invent messages.
                """

                let raw = try await client.oneShot(system: system, user: userPrompt)
                if Task.isCancelled { return }
                let parsed = Self.parseTriageJSON(raw, originals: messages)
                self.triagePanel.state.entries = parsed
                self.triagePanel.state.phase = .ready
                Log.write("Triage done: \(parsed.count) entries from \(messages.count) messages")
            } catch is CancellationError {
                Log.write("Triage cancelled")
            } catch {
                Log.write("Triage error: \(error.localizedDescription)")
                self.triagePanel.state.phase = .error(error.localizedDescription)
            }
            self.triageTask = nil
        }
    }

    private func triageSelect(_ entry: TriageEntry) {
        Log.write("Triage select id=\(entry.messageID)")
        do {
            try MailBridge.selectMessage(id: entry.messageID)
        } catch {
            notify("Could not select that message: \(error.localizedDescription)")
        }
    }

    private static func parseTriageJSON(_ raw: String, originals: [TriageMessage]) -> [TriageEntry] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8) else { return [] }
        let decoded = (try? JSONDecoder().decode([TriageEntry].self, from: data)) ?? []
        let byIndex = Dictionary(uniqueKeysWithValues: originals.map { ($0.index, $0) })
        return decoded.compactMap { entry in
            guard let orig = byIndex[entry.index] else { return nil }
            var e = entry
            e.sender = orig.sender
            e.subject = orig.subject
            e.messageID = orig.messageID
            return e
        }
    }

    // MARK: - Voice-to-task flow

    private let taskCapture = TaskCapture()

    func runVoiceTask() async {
        Log.write("=== runVoiceTask() start ===")
        guard let openaiKey = KeychainHelper.load(for: .openai), !openaiKey.isEmpty else {
            Log.write("missing OpenAI key for Whisper")
            notify("Set your OpenAI API key in Settings (required for voice dictation).")
            return
        }
        _ = openaiKey

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

        let granted = await AudioRecorder.ensurePermission()
        guard granted else {
            promptForMicrophone()
            return
        }
        let remindersGranted = await TaskCapture.ensureRemindersPermission()
        guard remindersGranted else {
            promptForReminders()
            return
        }

        await taskCapture.start(client: client, notifier: { [weak self] msg in self?.notify(msg) })
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
        alert.messageText = NSLocalizedString("Accessibility permission needed", comment: "")
        alert.informativeText = NSLocalizedString("MailMate needs Accessibility permission to paste the reply into Mail.\n\nThe reply is already on your clipboard — you can paste it manually with ⌘V.\n\nTo fix this for future replies: open System Settings → Privacy & Security → Accessibility, then enable MailMate.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
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
        alert.messageText = NSLocalizedString("Microphone access needed", comment: "")
        alert.informativeText = NSLocalizedString("MailMate needs microphone access to dictate replies.\n\nOpen System Settings → Privacy & Security → Microphone and enable MailMate.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func promptForReminders() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Reminders access needed", comment: "")
        alert.informativeText = NSLocalizedString("MailMate saves dictated tasks to Apple Reminders.\n\nOpen System Settings → Privacy & Security → Reminders and enable MailMate.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
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
