import Foundation

struct ReplyVariants {
    let short: String
    let standard: String
    let detailed: String

    /// All non-empty variants in order (short, standard, detailed).
    var nonEmpty: [(label: String, text: String)] {
        [("Short", short), ("Standard", standard), ("Detailed", detailed)]
            .filter { !$0.text.isEmpty }
    }
}

/// Parses model output containing `===SHORT===`, `===STANDARD===`, `===DETAILED===`
/// delimiters into three variants. Falls back to treating the full text as the
/// Standard variant if no delimiters are found.
enum VariantParser {
    static func parse(_ raw: String) -> ReplyVariants {
        func slice(_ key: String, in text: String) -> String {
            let pattern = #"(?m)^\s*===\#(key)===\s*$\n?([\s\S]*?)(?=^\s*===[A-Z]+===\s*$|\z)"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return "" }
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
                return ""
            }
            let captured = ns.substring(with: match.range(at: 1))
            return captured.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let short = slice("SHORT", in: raw)
        let standard = slice("STANDARD", in: raw)
        let detailed = slice("DETAILED", in: raw)

        if short.isEmpty && standard.isEmpty && detailed.isEmpty {
            return ReplyVariants(
                short: "",
                standard: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                detailed: ""
            )
        }
        return ReplyVariants(short: short, standard: standard, detailed: detailed)
    }
}

/// Shared prompts used by both providers so output structure is provider-agnostic.
enum VariantPrompt {
    private static let baseRules = """
    - Reply in the SAME LANGUAGE as the incoming email (detect from the body, not the sender name).
    - Match the sender's level of formality.
    - If a concrete commitment (date, price, meeting, deliverable) is implied, flag it with [CONFIRM] inline rather than committing.
    - Keep it concise — no filler, no "I hope this email finds you well".
    - Output ONLY the reply body. No subject line. No signature — Mail.app appends the user's signature automatically.
    - Do not include any quoted original text or "On <date>, X wrote:" — the draft already has that.
    """

    static func systemPrompt(rules: String) -> String {
        """
        You are an email assistant drafting reply bodies on behalf of the user.

        ## User rules
        \(rules)

        ## Always
        \(baseRules)

        ## Output format
        Return EXACTLY three variants, each preceded by its marker on its own line:

        ===SHORT===
        <a terse 1-2 sentence reply, direct and to the point>

        ===STANDARD===
        <a normal-length reply that follows the rules above>

        ===DETAILED===
        <a longer reply that addresses points more thoroughly, adds relevant caveats, and may include short paragraphs or a list>

        Do NOT include any text outside these three sections. Do not add preamble.
        """
    }

    static func dictationSystemPrompt(rules: String) -> String {
        """
        You are an email assistant. The user has dictated, in colloquial speech, what they want to say. Turn that dictation into a proper email reply body that follows their rules.

        ## User rules
        \(rules)

        ## Always
        - Use the SAME LANGUAGE as the dictation (Dutch or English — detect).
        - Preserve the user's intent verbatim — do NOT add facts, dates, prices, or commitments the user did not dictate.
        - If the dictation is ambiguous about a concrete detail, flag it inline with [CONFIRM] rather than inventing one.
        - Clean up filler ("eh", "uhm"), false starts, and duplicated phrases. Keep the tone natural, not over-polished.
        - Output ONLY the reply body. No subject line, no signature, no quoted original. One single reply — do NOT produce multiple variants.
        """
    }

    static func userPrompt(for email: MailMessage) -> String {
        """
        From: \(email.sender)
        Subject: \(email.subject)

        \(email.body)
        """
    }

    static func dictationUserPrompt(email: MailMessage, transcript: String) -> String {
        """
        Original email I'm replying to:
        From: \(email.sender)
        Subject: \(email.subject)

        \(email.body)

        ---

        What I want to say (dictated):
        \(transcript)
        """
    }
}

struct AnthropicClient: ReplyProvider {
    let apiKey: String
    var model: String = ProviderKind.anthropic.defaultModel
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
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        if let http = response as? HTTPURLResponse {
            Log.write("Anthropic stream HTTP status=\(http.statusCode)")
            if http.statusCode >= 400 {
                var errBody = ""
                for try await line in bytes.lines { errBody += line + "\n" }
                Log.write("Anthropic stream error body: \(errBody)")
                throw NSError(domain: "Anthropic", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errBody)"])
            }
        }

        var accumulated = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let jsonData = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    accumulated += text
                    let snapshot = accumulated
                    await onChunk(snapshot)
                }
            case "message_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let stop = delta["stop_reason"] as? String, stop != "end_turn" {
                    Log.write("Anthropic stop_reason=\(stop)")
                }
            case "message_stop":
                break
            case "error":
                let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                throw NSError(domain: "Anthropic", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Stream error: \(message)"])
            default:
                break
            }
        }
        Log.write("Anthropic stream complete, total chars=\(accumulated.count)")
        return accumulated
    }
}
