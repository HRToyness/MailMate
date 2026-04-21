import Foundation

struct OpenAIClient: ReplyProvider {
    let apiKey: String
    var model: String = ProviderKind.openai.defaultModel
    var maxTokens: Int = 4096

    func streamVariants(
        email: MailMessage,
        rules: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try await streamChat(
            system: VariantPrompt.systemPrompt(rules: rules),
            user: VariantPrompt.userPrompt(for: email),
            onChunk: onChunk
        )
    }

    func streamDictatedReply(
        transcript: String,
        email: MailMessage,
        rules: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try await streamChat(
            system: VariantPrompt.dictationSystemPrompt(rules: rules),
            user: VariantPrompt.dictationUserPrompt(email: email, transcript: transcript),
            onChunk: onChunk
        )
    }

    private func streamChat(
        system: String,
        user: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse {
            Log.write("OpenAI stream HTTP status=\(http.statusCode)")
            if http.statusCode >= 400 {
                var errBody = ""
                for try await line in bytes.lines { errBody += line + "\n" }
                Log.write("OpenAI stream error body: \(errBody)")
                let message = Self.extractErrorMessage(from: errBody) ?? errBody
                throw NSError(domain: "OpenAI", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(message)"])
            }
        }

        var accumulated = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let jsonData = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { continue }

            if let choices = obj["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                accumulated += content
                let snapshot = accumulated
                await onChunk(snapshot)
            }
            if let choices = obj["choices"] as? [[String: Any]],
               let first = choices.first,
               let finish = first["finish_reason"] as? String,
               finish != "stop" {
                Log.write("OpenAI finish_reason=\(finish)")
            }

            if let err = obj["error"] as? [String: Any] {
                let msg = err["message"] as? String ?? "unknown"
                throw NSError(domain: "OpenAI", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Stream error: \(msg)"])
            }
        }
        Log.write("OpenAI stream complete, total chars=\(accumulated.count)")
        return accumulated
    }

    private static func extractErrorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let msg = err["message"] as? String
        else { return nil }
        return msg
    }
}
