import Foundation

enum WhisperError: Error, LocalizedError {
    case missingOpenAIKey
    case fileUnreadable(String)
    case httpError(Int, String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingOpenAIKey:
            return "OpenAI API key is required for voice dictation (Whisper). Set it in Settings."
        case .fileUnreadable(let path):
            return "Could not read audio file at \(path)."
        case .httpError(let code, let msg):
            return "Whisper HTTP \(code): \(msg)"
        case .unexpectedResponse:
            return "Whisper returned an unexpected response."
        }
    }
}

struct WhisperClient {
    let apiKey: String
    var model: String = "whisper-1"

    static func make() throws -> WhisperClient {
        guard let key = KeychainHelper.load(for: .openai), !key.isEmpty else {
            throw WhisperError.missingOpenAIKey
        }
        return WhisperClient(apiKey: key)
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let data = try? Data(contentsOf: audioURL) else {
            throw WhisperError.fileUnreadable(audioURL.path)
        }

        let boundary = "----MailMateBoundary\(UUID().uuidString)"
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)
        appendField(name: "response_format", value: "json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        Log.write("Whisper request: bytes=\(data.count) model=\(model)")
        let (respData, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WhisperError.unexpectedResponse
        }
        Log.write("Whisper HTTP status=\(http.statusCode) bytes=\(respData.count)")

        if http.statusCode >= 400 {
            let msg = String(data: respData, encoding: .utf8) ?? "<no body>"
            Log.write("Whisper error body: \(msg)")
            throw WhisperError.httpError(http.statusCode, Self.extractErrorMessage(from: msg) ?? msg)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let text = obj["text"] as? String else {
            throw WhisperError.unexpectedResponse
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.write("Whisper transcript length=\(trimmed.count)")
        return trimmed
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
