import Foundation

/// One finished transcription of a meeting. A meeting keeps every one it has
/// had, so the history can show re-transcriptions.
struct TranscriptionRecord: Codable, Equatable, Identifiable {
    var engine: String            // Engine.rawValue
    var model: String             // e.g. "large-v3-q5_0"
    var finishedAt: Date
    /// Seconds of audio sent through the engine, both tracks together.
    var audioSeconds: Double
    /// Wall-clock time the transcription took.
    var processingSeconds: Double
    /// What a run on a paid API cost, from when Ata had one; 0 ever since. It stays
    /// because it is required in stored meetings: older copies of Ata on the same
    /// iCloud can't read a meeting without it, and a meeting they can't read vanishes.
    var costUSD: Double
    var words: Int
    var mySpeechSeconds: Double
    var othersSpeechSeconds: Double
    /// File name inside `versions/` once a newer transcription replaced this one.
    var archivedAs: String?

    var id: String { "\(finishedAt.timeIntervalSince1970)-\(model)" }
    /// On this device, whichever engine: whisper.cpp or Apple's speech recognition.
    var isLocal: Bool { Engine(rawValue: engine)?.isLocal ?? false }
}
