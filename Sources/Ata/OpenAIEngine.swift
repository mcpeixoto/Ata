import Foundation

/// Transcribes by uploading the audio to OpenAI.
///
/// Opt-in: the user has to pick this engine and paste an API key. When it is
/// selected the recorded audio leaves the Mac, which the UI states plainly.
enum OpenAIEngine {
    /// OpenAI rejects uploads over 25 MB. A 16 kHz mono 16-bit track is
    /// 32 kB/s, so ten minutes is ~19 MB — comfortably under the limit.
    static let chunkSeconds = 600

    struct Result {
        let segments: [Segment]
        /// True when the model returned no timestamps, so echo removal is skipped.
        let coarse: Bool
    }

    static func transcribe(audio: URL, speaker: String, language: String, model: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        guard let client = OpenAIClient() else { throw OpenAIError.noKey }

        let scratch = audio.deletingLastPathComponent().appendingPathComponent(".upload", isDirectory: true)
        let chunks = try AudioFiles.split(audio, maxSeconds: chunkSeconds, into: scratch)
        defer {
            AudioFiles.cleanUp(chunks)
            try? FileManager.default.removeItem(at: scratch)
        }
        guard !chunks.isEmpty else { throw OpenAIError.audioTooShort }

        var segments: [Segment] = []
        var coarse = false
        for (i, chunk) in chunks.enumerated() {
            progress(Double(i) / Double(chunks.count))
            let piece = try await client.transcribe(audio: chunk.url, model: model, language: language)
            coarse = coarse || piece.coarse
            for s in piece.segments {
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !Transcriber.isNoise(text) else { continue }
                // A coarse chunk has no internal timing: span it across the chunk
                // so speakers still interleave in the right order.
                let end = s.end > s.start ? s.end : chunkSeconds * 1000
                segments.append(Segment(speaker: speaker,
                                        start: chunk.offsetMs + s.start,
                                        end: chunk.offsetMs + end,
                                        text: text))
            }
        }
        progress(1)
        return Result(segments: segments, coarse: coarse)
    }
}
