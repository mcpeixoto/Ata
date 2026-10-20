import Foundation

enum OpenAIError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse
    case audioTooShort

    var errorDescription: String? {
        switch self {
        case .noKey:
            return L("No OpenAI API key. Add one in Settings → Transcription.")
        case .http(let code, let message):
            return message.isEmpty ? L("OpenAI returned HTTP %d.", code) : L("OpenAI: %@", message)
        case .badResponse:
            return L("Could not read OpenAI's response.")
        case .audioTooShort:
            return L("The recording is too short to transcribe.")
        }
    }
}

/// Thin client for the two OpenAI endpoints Ata uses: audio transcription and
/// chat completions (for the optional summary).
///
/// Only reached when the user picks the OpenAI engine — the local engine never
/// touches the network.
struct OpenAIClient {
    let apiKey: String
    private static let base = URL(string: "https://api.openai.com/v1")!

    init?(key: String? = Keychain.get(Keychain.openAIKey)) {
        guard let key, !key.isEmpty else { return nil }
        self.apiKey = key
    }

    // MARK: - Transcription

    struct TranscriptionChunk {
        /// Segments with millisecond offsets relative to the start of the chunk.
        let segments: [(start: Int, end: Int, text: String)]
        /// True when the model only returned flat text, so offsets are chunk-coarse.
        let coarse: Bool
    }

    /// Transcribes one audio file. `model` is an OpenAI transcription model id.
    func transcribe(audio: URL, model: String, language: String) async throws -> TranscriptionChunk {
        var fields: [String: String] = ["model": model]
        if language != "auto" { fields["language"] = language }

        // Only whisper-1 returns per-segment timestamps.
        let wantsSegments = model == "whisper-1"
        fields["response_format"] = wantsSegments ? "verbose_json" : "json"

        let body = try multipart(fields: fields, fileURL: audio, fileField: "file")
        var req = URLRequest(url: Self.base.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(Self.boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let data = try await send(req, body: body)

        if wantsSegments, let parsed = try? JSONDecoder().decode(VerboseResponse.self, from: data),
           let segments = parsed.segments, !segments.isEmpty {
            return TranscriptionChunk(
                segments: segments.map {
                    (start: Int(($0.start * 1000).rounded()),
                     end: Int(($0.end * 1000).rounded()),
                     text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
                },
                coarse: false)
        }

        guard let plain = try? JSONDecoder().decode(PlainResponse.self, from: data) else {
            throw OpenAIError.badResponse
        }
        let text = plain.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return TranscriptionChunk(segments: [], coarse: true) }
        return TranscriptionChunk(segments: [(start: 0, end: 0, text: text)], coarse: true)
    }

    // MARK: - Chat (summary)

    struct Completion {
        let text: String
        let inputTokens: Int
        let outputTokens: Int
    }

    func complete(system: String, user: String, model: String) async throws -> Completion {
        var req = URLRequest(url: Self.base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await send(req, body: body)
        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let text = parsed.choices.first?.message.content else {
            throw OpenAIError.badResponse
        }
        return Completion(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          inputTokens: parsed.usage?.prompt_tokens ?? 0,
                          outputTokens: parsed.usage?.completion_tokens ?? 0)
    }

    /// Verifies the key works, without spending tokens on audio.
    func validate() async throws {
        var req = URLRequest(url: Self.base.appendingPathComponent("models"))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        _ = try await send(req, body: nil)
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest, body: Data?) async throws -> Data {
        var req = request
        let (data, response): (Data, URLResponse)
        if let body {
            (data, response) = try await URLSession.shared.upload(for: req, from: body)
        } else {
            req.httpMethod = req.httpMethod ?? "GET"
            (data, response) = try await URLSession.shared.data(for: req)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw OpenAIError.http(code, Self.errorMessage(data))
        }
        return data
    }

    private static func errorMessage(_ data: Data) -> String {
        if let wrapper = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            return wrapper.error.message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    private static let boundary = "AtaBoundary7F3A1C"

    private func multipart(fields: [String: String], fileURL: URL, fileField: String) throws -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            append("--\(Self.boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(Self.boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        append("Content-Type: \(Self.mimeType(for: fileURL))\r\n\r\n")
        body.append(try Data(contentsOf: fileURL, options: .mappedIfSafe))
        append("\r\n--\(Self.boundary)--\r\n")
        return body
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Response shapes

    private struct VerboseResponse: Decodable {
        struct Segment: Decodable { let start: Double; let end: Double; let text: String }
        let segments: [Segment]?
    }

    private struct PlainResponse: Decodable { let text: String }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        struct Usage: Decodable { let prompt_tokens: Int; let completion_tokens: Int }
        let choices: [Choice]
        let usage: Usage?
    }

    private struct ErrorResponse: Decodable {
        struct Payload: Decodable { let message: String }
        let error: Payload
    }
}
