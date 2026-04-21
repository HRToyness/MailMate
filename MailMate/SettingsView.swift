import SwiftUI

struct SettingsView: View {
    @State private var provider: ProviderKind = ProviderFactory.current

    @State private var anthropicKey: String = KeychainHelper.load(for: .anthropic) ?? ""
    @State private var anthropicModel: String = UserDefaults.standard
        .string(forKey: ProviderKind.anthropic.modelDefaultsKey) ?? ProviderKind.anthropic.defaultModel

    @State private var openaiKey: String = KeychainHelper.load(for: .openai) ?? ""
    @State private var openaiModel: String = UserDefaults.standard
        .string(forKey: ProviderKind.openai.modelDefaultsKey) ?? ProviderKind.openai.defaultModel

    @State private var savedFlash = false
    @State private var saveError: String?

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
            }

            Section("OpenAI (ChatGPT)") {
                SecureField("API key", text: $openaiKey)
                TextField("Model", text: $openaiModel)
                    .help("e.g. gpt-4.1-mini, gpt-4o")
            }

            HStack {
                Button("Save") { save() }
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
        .frame(width: 520, height: 360)
    }

    private func save() {
        UserDefaults.standard.set(provider.rawValue, forKey: "provider")

        let trimmedAnthropic = anthropicModel.trimmingCharacters(in: .whitespaces)
        let finalAnthropicModel = trimmedAnthropic.isEmpty ? ProviderKind.anthropic.defaultModel : trimmedAnthropic
        UserDefaults.standard.set(finalAnthropicModel, forKey: ProviderKind.anthropic.modelDefaultsKey)

        let trimmedOpenAI = openaiModel.trimmingCharacters(in: .whitespaces)
        let finalOpenAIModel = trimmedOpenAI.isEmpty ? ProviderKind.openai.defaultModel : trimmedOpenAI
        UserDefaults.standard.set(finalOpenAIModel, forKey: ProviderKind.openai.modelDefaultsKey)

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
