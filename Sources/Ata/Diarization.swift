import FluidAudio
import Foundation

/// Which `Diarizer` Ata uses.
///
/// FluidAudio's offline pipeline (pyannote segmentation, WeSpeaker embeddings,
/// VBx clustering) on Core ML. Its models — about 21 MB — are downloaded from
/// Hugging Face the first time voice recognition runs, and live in
/// ~/Library/Application Support/FluidAudio.
///
/// macOS 15 or later only: an Apple bug in macOS 14 crashes this pipeline
/// intermittently, and a feature that can take the app down is not worth having.
enum Diarization {
    static var isSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
    }

    static var current: Diarizer? { isSupported ? FluidDiarizer() : nil }
}

/// A fresh diarizer per meeting: FluidAudio's manager is not Sendable, and
/// one job at a time is all the queue runs anyway.
struct FluidDiarizer: Diarizer {
    /// Speakers with less speech than this are labelled but not learned:
    /// a cough or a two-word reply makes a poor fingerprint.
    static let minimumSecondsToLearn = 10.0

    func diarize(_ wav: URL) async throws -> (turns: [SpeakerTurn], embeddings: [String: [Float]]) {
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        let samples = try AudioConverter().resampleAudioFile(wav)
        let result = try await manager.process(audio: samples)

        let turns = result.segments.map {
            SpeakerTurn(start: Int(($0.startTimeSeconds * 1000).rounded()),
                        end: Int(($0.endTimeSeconds * 1000).rounded()),
                        label: $0.speakerId)
        }
        var embeddings: [String: [Float]] = [:]
        for (id, e) in result.speakerDatabase ?? [:] {
            let seconds = result.segments.filter { $0.speakerId == id }.reduce(0.0) { $0 + Double($1.durationSeconds) }
            if seconds >= Self.minimumSecondsToLearn { embeddings[id] = e }
        }
        return (turns, embeddings)
    }

    /// Your microphone track is one speaker by construction, so the same
    /// pipeline's per-speaker embedding of its main speaker is your voice.
    func embed(_ wav: URL) async throws -> [Float]? {
        let found = try await diarize(wav)
        let main = Dictionary(grouping: found.turns, by: \.label)
            .mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
            .max { $0.value < $1.value }?.key
        return main.flatMap { found.embeddings[$0] }
    }
}
