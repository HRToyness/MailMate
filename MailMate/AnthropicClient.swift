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

    static func systemPrompt(rules: String, calendar: String? = nil) -> String {
        var out = """
        You are an email assistant drafting reply bodies on behalf of the user.

        ## User rules
        \(rules)

        ## Always
        \(baseRules)
        """
        if let calendar, !calendar.isEmpty {
            out += """


        ## My calendar
        Use this to propose ACTUAL free time if the email is about scheduling. Prefer specific proposals over "[CONFIRM — check calendar]" when the calendar clearly shows availability. Still flag [CONFIRM] for commitments outside the shown window.

        \(calendar)
        """
        }
        out += """


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
        return out
    }

    static func summarySystemPrompt() -> String {
        """
        You are an email assistant. Summarize the given email thread concisely in the SAME LANGUAGE as the messages. Focus on:

        1. The core topic and what's being asked of the user.
        2. Any commitments or deadlines on the table (with dates).
        3. Outstanding questions that need an answer.
        4. Who said what (only when it matters for the user's reply).

        Output format (plain text, no preamble):
        - 1-paragraph executive summary (2-4 sentences).
        - Bullet list "Action items for you" with at most 5 items. If there are no actions, write "- None." under that heading.

        Do NOT suggest a reply. Do NOT include greetings or meta-commentary.
        """
    }

    static func summaryUserPrompt(email: MailMessage, priorThread: [MailMessage]) -> String {
        var out = "THREAD (most recent last):\n"
        let ordered = priorThread.reversed() + [email]
        for (i, m) in ordered.enumerated() {
            out += "\n--- Message \(i + 1) ---\n"
            if let d = m.dateReceived { out += "Date: \(d)\n" }
            out += "From: \(m.sender)\nSubject: \(m.subject)\n\n\(m.body)\n"
        }
        return out
    }

    static func dictationSystemPrompt(rules: String, calendar: String? = nil) -> String {
        var out = """
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
        if let calendar, !calendar.isEmpty {
            out += """


        ## My calendar
        Use this if the user's dictation involves proposing a meeting time. Prefer specific proposals over generic "let me check" when availability is clear.

        \(calendar)
        """
        }
        return out
    }

    static func userPrompt(for email: MailMessage, priorThread: [MailMessage] = []) -> String {
        var out = """
        From: \(email.sender)
        Subject: \(email.subject)

        \(email.body)
        """
        if !priorThread.isEmpty {
            out += "\n\n---\nEarlier messages in this thread (oldest first):\n"
            for msg in priorThread.reversed() {
                out += "\n"
                if let date = msg.dateReceived { out += "Date: \(date)\n" }
                out += "From: \(msg.sender)\nSubject: \(msg.subject)\n\n\(msg.body)\n"
            }
        }
        return out
    }

    static func dictationUserPrompt(email: MailMessage, transcript: String, priorThread: [MailMessage] = []) -> String {
        var out = """
        Original email I'm replying to:
        From: \(email.sender)
        Subject: \(email.subject)

        \(email.body)
        """
        if !priorThread.isEmpty {
            out += "\n\n---\nEarlier messages in this thread (oldest first):\n"
            for msg in priorThread.reversed() {
                out += "\n"
                if let date = msg.dateReceived { out += "Date: \(date)\n" }
                out += "From: \(msg.sender)\nSubject: \(msg.subject)\n\n\(msg.body)\n"
            }
        }
        out += "\n\n---\n\nWhat I want to say (dictated):\n\(transcript)"
        return out
    }
}

struct AnthropicClient: ReplyProvider {
    let apiKey: String
    var model: String = ProviderKind.anthropic.defaultModel
    var maxTokens: Int = 4096

    func streamVariants(
        email: MailMessage,
        priorThread: [MailMessage],
        rules: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let calendar = await CalendarContext.summaryIfEnabled()
        return try await streamChat(
            system: VariantPrompt.systemPrompt(rules: rules, calendar: calendar),
            user: VariantPrompt.userPrompt(for: email, priorThread: priorThread),
            onChunk: onChunk
        )
    }

    func streamDictatedReply(
        transcript: String,
        email: MailMessage,
        priorThread: [MailMessage],
        rules: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let calendar = await CalendarContext.summaryIfEnabled()
        return try await streamChat(
            system: VariantPrompt.dictationSystemPrompt(rules: rules, calendar: calendar),
            user: VariantPrompt.dictationUserPrompt(email: email, transcript: transcript, priorThread: priorThread),
            onChunk: onChunk
        )
    }

    func streamSummary(
        email: MailMessage,
        priorThread: [MailMessage],
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        try await streamChat(
            system: VariantPrompt.summarySystemPrompt(),
            user: VariantPrompt.summaryUserPrompt(email: email, priorThread: priorThread),
            onChunk: onChunk
        )
    }

    func oneShot(system: String, user: String) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Anthropic", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg)"])
        }
        struct APIResponse: Decodable {
            struct Content: Decodable { let type: String; let text: String? }
            let content: [Content]
        }
        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        let text = decoded.content.first(where: { $0.type == "text" })?.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testConnection() async throws {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 5,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Anthropic", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        if http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Anthropic", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg)"])
        }
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
