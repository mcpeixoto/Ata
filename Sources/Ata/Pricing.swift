import Foundation

/// One finished transcription of a meeting. A meeting keeps every one it has
/// had, so the history can show re-transcriptions and what each cost.
struct TranscriptionRecord: Codable, Equatable, Identifiable {
    var engine: String            // Engine.rawValue
    var model: String             // e.g. "large-v3-turbo", "whisper-1"
    var finishedAt: Date
    /// Seconds of audio sent through the engine, both tracks together.
    var audioSeconds: Double
    /// Wall-clock time the transcription took.
    var processingSeconds: Double
    /// Estimated OpenAI cost in US dollars, transcription and summary together. 0 when local.
    var costUSD: Double
    var words: Int
    var mySpeechSeconds: Double
    var othersSpeechSeconds: Double
    /// File name inside `versions/` once a newer transcription replaced this one.
    var archivedAs: String?

    var id: String { "\(finishedAt.timeIntervalSince1970)-\(model)" }
    var isLocal: Bool { engine == Engine.local.rawValue }
}

/// OpenAI list prices, used to estimate what a transcription cost.
///
/// The API reports token usage but never money, so this table is the only
/// source; it is dated so a stale price is easy to spot, and every figure the
/// UI shows from it is labelled as an estimate.
enum Pricing {
    static let asOf = "2026-10"

    /// US dollars per minute of audio.
    static let transcriptionPerMinute: [String: Double] = [
        "whisper-1": 0.006,
        "gpt-4o-transcribe": 0.006,
        "gpt-4o-mini-transcribe": 0.003,
    ]

    /// US dollars per million tokens, (input, output).
    static let chatPerMillion: [String: (input: Double, output: Double)] = [
        "gpt-4o-mini": (0.15, 0.60),
        "gpt-4o": (2.50, 10.00),
        "gpt-4.1-mini": (0.40, 1.60),
        "gpt-4.1": (2.00, 8.00),
    ]

    static func transcription(model: String, seconds: Double) -> Double {
        (transcriptionPerMinute[model] ?? 0.006) * seconds / 60
    }

    static func chat(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        let p = chatPerMillion[model] ?? (0.15, 0.60)
        return (Double(inputTokens) * p.input + Double(outputTokens) * p.output) / 1_000_000
    }

    /// What the same audio would have cost on OpenAI's cheapest timestamped
    /// model, for the "saved by transcribing locally" figure.
    static func localSavings(seconds: Double) -> Double {
        transcription(model: "whisper-1", seconds: seconds)
    }

    static func format(_ usd: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = usd > 0 && usd < 1 ? 3 : 2
        f.minimumFractionDigits = 2
        return f.string(from: NSNumber(value: usd)) ?? String(format: "$%.2f", usd)
    }
}
