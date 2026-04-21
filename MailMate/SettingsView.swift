import SwiftUI

struct SettingsView: View {
    @State private var provider: ProviderKind = ProviderFactory.current

    @State private var anthropicKey: String = KeychainHelper.load(for: .anthropic) ?? ""
    @State private var anthropicModel: String = UserDefaults.standard
        .string(forKey: ProviderKind.anthropic.modelDefaultsKey) ?? ProviderKind.anthropic.defaultModel

    @State private var openaiKey: String = KeychainHelper.load(for: .openai) ?? ""
    @State private var openaiModel: String = UserDefaults.standard
        .string(forKey: ProviderKind.openai.modelDefaultsKey) ?? ProviderKind.openai.defaultModel

    @State private var whisperLanguage: String = UserDefaults.standard.string(forKey: "whisper_language") ?? ""
    @State private var includeThread: Bool = UserDefaults.standard.bool(forKey: "include_thread")
    @State private var includeCalendar: Bool = UserDefaults.standard.bool(forKey: "include_calendar")
    @State private var launchAtLogin: Bool = LoginItem.isEnabled

    @State private var savedFlash = false
    @State private var saveError: String?

    @State private var anthropicTestStatus: TestStatus = .idle
    @State private var openaiTestStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle, running, success, failure(String)
    }

    var body: some View {
        Form {
            Picker("Active provider", selection: $provider) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            Section("Anthropic (Claude)") {
                SecureField("API key", text: $anthropicKey)
                TextField("Model", text: $anthropicModel)
                    .help("e.g. claude-sonnet-4-5, claude-opus-4-7")
                HStack {
                    Button("Test connection") {
                        Task { await runTest(.anthropic) }
                    }
                    testStatusView(anthropicTestStatus)
                    Spacer()
                }
            }

            Section("OpenAI (ChatGPT)") {
                SecureField("API key", text: $openaiKey)
                TextField("Model", text: $openaiModel)
                    .help("e.g. gpt-4.1-mini, gpt-4o")
                HStack {
                    Button("Test connection") {
                        Task { await runTest(.openai) }
                    }
                    testStatusView(openaiTestStatus)
                    Spacer()
                }
            }

            Section("Voice dictation") {
                Picker("Dictation language", selection: $whisperLanguage) {
                    Text("Auto-detect").tag("")
                    Text("English (en)").tag("en")
                    Text("Dutch (nl)").tag("nl")
                }
                .help("Whisper transcription language. Auto-detect works well for most cases; set a specific language if short clips get misdetected.")
            }

            Section("Context") {
                Toggle("Include prior thread messages (experimental)", isOn: $includeThread)
                    .help("Fetches up to 8 earlier messages with the same subject from the same mailbox. May be slow on large mailboxes.")
                Toggle("Include my calendar when drafting replies", isOn: $includeCalendar)
                    .help("When drafting a reply that involves scheduling, MailMate includes your next 7 days of busy windows so the model can propose real free times. Requires Calendar permission.")
            }

            Section("System") {
                Toggle("Launch MailMate at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        let ok = LoginItem.setEnabled(newValue)
                        if !ok { launchAtLogin = LoginItem.isEnabled }
                    }
            }

            HStack {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                if savedFlash {
                    Text("Saved").foregroundColor(.green).font(.caption)
                }
                if let saveError {
                    Text(saveError).foregroundColor(.red).font(.caption)
                }
                Spacer()
                Button("Edit rules file") {
                    RulesLoader.openInEditor()
                }
            }
        }
        .padding()
        .frame(width: 560, height: 560)
    }

    @ViewBuilder
    private func testStatusView(_ status: TestStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .success:
            Text("✓ OK").font(.caption).foregroundStyle(.green)
        case .failure(let msg):
            Text("✗ \(msg)")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @MainActor
    private func runTest(_ kind: ProviderKind) async {
        // Save just the specific key + model so the test uses what's in the
        // UI rather than the previously-persisted values.
        let keyInUI = (kind == .anthropic) ? anthropicKey : openaiKey
        let modelInUI = (kind == .anthropic) ? anthropicModel : openaiModel
        if keyInUI.isEmpty {
            setTest(kind, .failure("Paste an API key first."))
            return
        }
        setTest(kind, .running)
        let effectiveModel = modelInUI.trimmingCharacters(in: .whitespaces)
        let client: ReplyProvider = {
            switch kind {
            case .anthropic:
                return AnthropicClient(apiKey: keyInUI,
                                       model: effectiveModel.isEmpty ? kind.defaultModel : effectiveModel)
            case .openai:
                return OpenAIClient(apiKey: keyInUI,
                                    model: effectiveModel.isEmpty ? kind.defaultModel : effectiveModel)
            }
        }()
        do {
            try await client.testConnection()
            setTest(kind, .success)
        } catch {
            setTest(kind, .failure(error.localizedDescription))
        }
    }

    private func setTest(_ kind: ProviderKind, _ status: TestStatus) {
        switch kind {
        case .anthropic: anthropicTestStatus = status
        case .openai:    openaiTestStatus = status
        }
    }

    private func save() {
        UserDefaults.standard.set(provider.rawValue, forKey: "provider")

        let trimmedAnthropic = anthropicModel.trimmingCharacters(in: .whitespaces)
        let finalAnthropicModel = trimmedAnthropic.isEmpty ? ProviderKind.anthropic.defaultModel : trimmedAnthropic
        UserDefaults.standard.set(finalAnthropicModel, forKey: ProviderKind.anthropic.modelDefaultsKey)

        let trimmedOpenAI = openaiModel.trimmingCharacters(in: .whitespaces)
        let finalOpenAIModel = trimmedOpenAI.isEmpty ? ProviderKind.openai.defaultModel : trimmedOpenAI
        UserDefaults.standard.set(finalOpenAIModel, forKey: ProviderKind.openai.modelDefaultsKey)

        UserDefaults.standard.set(whisperLanguage, forKey: "whisper_language")
        UserDefaults.standard.set(includeThread, forKey: "include_thread")
        UserDefaults.standard.set(includeCalendar, forKey: "include_calendar")

        var failures: [String] = []
        if !anthropicKey.isEmpty {
            if !KeychainHelper.save(anthropicKey, for: .anthropic) { failures.append("Anthropic") }
        }
        if !openaiKey.isEmpty {
            if !KeychainHelper.save(openaiKey, for: .openai) { failures.append("OpenAI") }
        }

        if failures.isEmpty {
            saveError = nil
            savedFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { savedFlash = false }
        } else {
            savedFlash = false
            saveError = "Keychain write failed for: \(failures.joined(separator: ", "))"
        }
    }
}
