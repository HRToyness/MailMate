import Foundation

enum ProviderKind: String, CaseIterable, Identifiable {
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (ChatGPT)"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-5"
        case .openai: return "gpt-4.1-mini"
        }
    }

    var modelDefaultsKey: String {
        switch self {
        case .anthropic: return "model_anthropic"
        case .openai: return "model_openai"
        }
    }

    var keychainAccount: String {
        switch self {
        case .anthropic: return "anthropic-api-key"
        case .openai: return "openai-api-key"
        }
    }
}

protocol ReplyProvider {
    func streamVariants(
        email: MailMessage,
        rules: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String

    func streamDictatedReply(
        transcript: String,
        email: MailMessage,
        rules: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String
}

enum ProviderError: Error, LocalizedError {
    case missingAPIKey(ProviderKind)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let kind):
            return "No API key set for \(kind.displayName). Open Settings and paste one."
        }
    }
}

enum ProviderFactory {
    /// Returns the currently-selected provider kind from UserDefaults.
    static var current: ProviderKind {
        let raw = UserDefaults.standard.string(forKey: "provider") ?? ProviderKind.anthropic.rawValue
        return ProviderKind(rawValue: raw) ?? .anthropic
    }

    /// Builds a client for the given provider using the stored API key and model.
    /// Throws `missingAPIKey` if the Keychain has no entry for that provider.
    static func make(_ kind: ProviderKind) throws -> ReplyProvider {
        guard let apiKey = KeychainHelper.load(for: kind), !apiKey.isEmpty else {
            throw ProviderError.missingAPIKey(kind)
        }
        let model = UserDefaults.standard.string(forKey: kind.modelDefaultsKey) ?? kind.defaultModel
        switch kind {
        case .anthropic:
            return AnthropicClient(apiKey: apiKey, model: model)
        case .openai:
            return OpenAIClient(apiKey: apiKey, model: model)
        }
    }

    /// One-time migration on launch: backfill defaults from the old single-provider layout.
    static func runMigrationsIfNeeded() {
        let d = UserDefaults.standard
        if d.string(forKey: "provider") == nil {
            d.set(ProviderKind.anthropic.rawValue, forKey: "provider")
        }
        if d.string(forKey: ProviderKind.anthropic.modelDefaultsKey) == nil,
           let legacy = d.string(forKey: "model") {
            d.set(legacy, forKey: ProviderKind.anthropic.modelDefaultsKey)
        }
    }
}
