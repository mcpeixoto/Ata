import Foundation

/// Transcribes by uploading the audio to OpenAI.
///
/// Opt-in: the user has to pick this engine and paste an API key. When it is
/// selected the recorded audio leaves the Mac, which the UI states plainly.
enum OpenAIEngine {
    /// OpenAI rejects uploads over 25 MB. A 16 kHz mono 16-bit track is
    /// 32 kB/s, so ten minutes is ~19 MB — comfortably under the limit.
    static let chunkSeconds = 600

    /// The gpt-4o transcription models cap their output at about 2,000 tokens,
    /// which ten minutes of dense speech can exceed — the end of the chunk would
    /// silently go missing. Five minutes stays well under it.
    static func chunkSeconds(for model: String) -> Int {
        model.hasPrefix("gpt-4o") ? 300 : chunkSeconds
    }

    struct Result {
        let segments: [Segment]
        /// True when the model returned no timestamps, so echo removal is skipped.
        let coarse: Bool
    }

    static func transcribe(audio: URL, speaker: String, language: String, model: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        guard let client = OpenAIClient() else { throw OpenAIError.noKey }

        let scratch = audio.deletingLastPathComponent().appendingPathComponent(".upload", isDirectory: true)
        let chunkLength = chunkSeconds(for: model)
        let chunks = try AudioFiles.split(audio, maxSeconds: chunkLength, into: scratch)
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
            let words = attach(words: piece.words, to: piece.segments)
            for (s, own) in zip(piece.segments, words) {
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !Transcriber.isNoise(text) else { continue }
                // A coarse chunk has no internal timing: span it across the chunk
                // so speakers still interleave in the right order.
                let end = s.end > s.start ? s.end : chunkLength * 1000
                segments.append(Segment(speaker: speaker,
                                        start: chunk.offsetMs + s.start,
                                        end: chunk.offsetMs + end,
                                        text: text,
                                        words: own.map { Segment.Word(start: chunk.offsetMs + $0.start,
                                                                      end: chunk.offsetMs + $0.end,
                                                                      text: $0.text) }))
            }
        }
        progress(1)
        return Result(segments: segments, coarse: coarse)
    }

    /// OpenAI returns words in one list beside the segments: each word goes to
    /// the segment its middle falls in, or the nearest one when it falls between two.
    static func attach(words: [(start: Int, end: Int, text: String)],
                       to segments: [(start: Int, end: Int, text: String)]) -> [[(start: Int, end: Int, text: String)]] {
        var out = segments.map { _ in [(start: Int, end: Int, text: String)]() }
        guard !segments.isEmpty else { return out }
        for w in words where !w.text.isEmpty {
            let mid = (w.start + w.end) / 2
            var best = 0, distance = Int.max
            for (i, s) in segments.enumerated() {
                let d = mid < s.start ? s.start - mid : (mid > s.end ? mid - s.end : 0)
                if d < distance { best = i; distance = d }
                if d == 0 { break }
            }
            out[best].append(w)
        }
        return out
    }
}
