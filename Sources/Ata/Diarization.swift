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

    /// Stored with every voice fingerprint: the embedding model of the offline
    /// pipeline (`speaker-diarization-coreml`, "Embedding") as pinned in Package.swift.
    /// Fingerprints from different models can't be compared, so voices from another
    /// model are never matched. Change it when a FluidAudio update changes the
    /// embedding model, and measure `VoiceLibrary.matchThreshold` again then; a
    /// version bump that keeps the model needs no change.
    static let embeddingModel = "fluidaudio-0.17.7-offline-embedding"

    /// What made a fingerprint saved without a tag: every voice learned before
    /// Ata 2.6. Keep this one as it is when `embeddingModel` changes.
    static let untaggedEmbeddingModel = "fluidaudio-0.17.7-offline-embedding"
}

/// A fresh diarizer per meeting: FluidAudio's manager is not Sendable, and
/// one job at a time is all the queue runs anyway.
struct FluidDiarizer: Diarizer {
    /// Speakers with less speech than this are labelled but not learned:
    /// a cough or a two-word reply makes a poor fingerprint.
    ///
    /// Ten seconds — the floor until 2.9 — is a lot to ask of a whole meeting.
    /// Someone who only answered a question, and every speaker of a short
    /// meeting, got no fingerprint, so no row and no name anywhere: the
    /// transcript said "Speaker 2" and the People tab said nobody else spoke.
    /// Five still rules out a cough, and a weak fingerprint now costs much less
    /// than it did, because the library no longer mints a duplicate whenever two
    /// of its voices resemble each other (`VoiceLibrary.assign`).
    static let minimumSecondsToLearn = 5.0

    func diarize(_ wav: URL) async throws -> (turns: [SpeakerTurn], embeddings: [String: [Float]]) {
        try await diarize(wav, minimumSecondsToLearn: Self.minimumSecondsToLearn)
    }

    func diarize(_ wav: URL, minimumSecondsToLearn: Double) async throws
        -> (turns: [SpeakerTurn], embeddings: [String: [Float]]) {
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
            if seconds >= minimumSecondsToLearn { embeddings[id] = e }
        }
        return (turns, embeddings)
    }

    /// On a call your microphone track is one speaker by construction, so the
    /// same pipeline's per-speaker embedding of its main speaker is your voice.
    /// In person it isn't, and the microphone is diarized instead; see `InPerson`.
    /// The share says which of those two a track turned out to be.
    func mainSpeaker(_ wav: URL, minimumSecondsToLearn: Double) async throws
        -> (embedding: [Float], share: Double)? {
        let found = try await diarize(wav, minimumSecondsToLearn: minimumSecondsToLearn)
        let spoken = Dictionary(grouping: found.turns, by: \.label)
            .mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
        let total = spoken.values.reduce(0, +)
        guard total > 0, let main = spoken.max { $0.value < $1.value },
              let embedding = found.embeddings[main.key] else { return nil }
        return (embedding, Double(main.value) / Double(total))
    }
}
