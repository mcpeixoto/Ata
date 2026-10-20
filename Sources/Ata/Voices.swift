import Foundation

/// A voice Ata has heard in one or more meetings.
///
/// Only a numeric fingerprint (a speaker embedding) and a few seconds of
/// sample audio are kept, both under Application Support and never uploaded —
/// not even when OpenAI transcribes.
struct Voice: Codable, Equatable, Identifiable {
    var id: UUID
    /// Nil until the user names it.
    var name: String?
    /// Running mean of every embedding matched to this voice, L2-normalised.
    var centroid: [Float]
    /// How many embeddings went into the centroid.
    var observations: Int
    var meetingIDs: [String]
    /// File name of a short sample inside the voices folder, for "play" in the UI.
    var sample: String?
    var firstSeen: Date
    var lastSeen: Date
    /// The person using this Mac, learned from the microphone track.
    var isMe: Bool = false

    var meetings: Int { meetingIDs.count }
}

/// One speaker found in one meeting, before or after matching.
struct MeetingSpeaker: Codable, Equatable {
    /// Stable within the meeting: "me", "S1", "S2"…
    var label: String
    var embedding: [Float]
    var seconds: Double
    var voiceID: UUID?
}

/// The local library of known voices, and the rules for matching against it.
final class VoiceLibrary {
    /// Cosine similarity at or above which an embedding is taken to be a known
    /// voice. Set from measurements; see docs/plans.
    static var matchThreshold: Float = 0.6

    /// An unnamed voice is worth asking about once it has turned up in this many meetings.
    static let askAfterMeetings = 2

    let file: URL
    private(set) var voices: [Voice] = []

    init(file: URL = Paths.voicesDir.appendingPathComponent("voices.json")) {
        self.file = file
        load()
    }

    // MARK: - Persistence

    /// ISO 8601 with fractional seconds, so saving and loading is lossless.
    private static let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func load() {
        guard let data = try? Data(contentsOf: file) else { voices = []; return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.dates.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "bad date \(text)"))
            }
            return date
        }
        voices = (try? d.decode([Voice].self, from: data)) ?? []
    }

    func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.dates.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(voices).write(to: file, options: [.atomic, .completeFileProtection])
    }

    // MARK: - Matching

    /// Assigns each speaker of one meeting to a known voice, or to a new one.
    ///
    /// Two speakers of the same meeting never get the same voice: pairs are
    /// taken best-similarity first, and a voice used once is off the table for
    /// the rest of that meeting. Matched voices learn from the new embedding.
    @discardableResult
    func assign(_ speakers: [MeetingSpeaker], meetingID: String, at date: Date = Date()) -> [MeetingSpeaker] {
        var result = speakers
        var candidates: [(speaker: Int, voice: Int, similarity: Float)] = []
        for (s, speaker) in speakers.enumerated() where !speaker.embedding.isEmpty {
            for (v, voice) in voices.enumerated() {
                let sim = Self.cosine(speaker.embedding, voice.centroid)
                if sim >= Self.matchThreshold { candidates.append((s, v, sim)) }
            }
        }
        candidates.sort { $0.similarity > $1.similarity }

        var takenSpeakers = Set<Int>(), takenVoices = Set<Int>()
        for c in candidates where !takenSpeakers.contains(c.speaker) && !takenVoices.contains(c.voice) {
            takenSpeakers.insert(c.speaker)
            takenVoices.insert(c.voice)
            learn(voice: c.voice, from: speakers[c.speaker], meetingID: meetingID, at: date)
            result[c.speaker].voiceID = voices[c.voice].id
        }

        for (s, speaker) in speakers.enumerated() where !takenSpeakers.contains(s) && !speaker.embedding.isEmpty {
            let voice = Voice(id: UUID(), name: nil, centroid: Self.normalised(speaker.embedding), observations: 1,
                              meetingIDs: [meetingID], sample: nil, firstSeen: date, lastSeen: date,
                              isMe: speaker.label == "me")
            voices.append(voice)
            result[s].voiceID = voice.id
        }
        return result
    }

    private func learn(voice i: Int, from speaker: MeetingSpeaker, meetingID: String, at date: Date) {
        var v = voices[i]
        let n = Float(v.observations)
        let mixed = zip(v.centroid, Self.normalised(speaker.embedding)).map { ($0 * n + $1) / (n + 1) }
        v.centroid = Self.normalised(mixed)
        v.observations += 1
        if !v.meetingIDs.contains(meetingID) { v.meetingIDs.append(meetingID) }
        v.lastSeen = max(v.lastSeen, date)
        if speaker.label == "me" { v.isMe = true }
        voices[i] = v
    }

    // MARK: - Editing

    func voice(_ id: UUID?) -> Voice? { id.flatMap { id in voices.first { $0.id == id } } }

    func rename(_ id: UUID, to name: String?) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        voices[i].name = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func setSample(_ id: UUID, file: String) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[i].sample = file
    }

    /// "These two are the same person": folds `source` into `target`.
    func merge(_ source: UUID, into target: UUID) {
        guard source != target,
              let s = voices.firstIndex(where: { $0.id == source }),
              let t = voices.firstIndex(where: { $0.id == target }) else { return }
        let a = voices[s], b = voices[t]
        let total = Float(a.observations + b.observations)
        var merged = b
        merged.centroid = Self.normalised(zip(a.centroid, b.centroid).map {
            ($0 * Float(a.observations) + $1 * Float(b.observations)) / total
        })
        merged.observations = a.observations + b.observations
        merged.meetingIDs = Array(Set(a.meetingIDs + b.meetingIDs)).sorted()
        merged.name = b.name ?? a.name
        merged.sample = b.sample ?? a.sample
        merged.firstSeen = min(a.firstSeen, b.firstSeen)
        merged.lastSeen = max(a.lastSeen, b.lastSeen)
        merged.isMe = a.isMe || b.isMe
        voices[t] = merged
        voices.remove(at: s)
    }

    func forget(_ id: UUID) {
        voices.removeAll { $0.id == id }
    }

    func forgetAll() {
        voices = []
    }

    /// Unnamed voices heard often enough to be worth naming, most frequent first.
    var worthAsking: [Voice] {
        voices.filter { $0.name == nil && !$0.isMe && $0.meetings >= Self.askAfterMeetings }
            .sorted { $0.meetings > $1.meetings }
    }

    // MARK: - Maths

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denominator = (na * nb).squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}

/// A stretch of time in which one speaker of the system track was talking.
struct SpeakerTurn: Codable, Equatable {
    var start: Int // ms
    var end: Int   // ms
    var label: String
}

enum SpeakerAssignment {
    /// The speaker label for a transcript segment of the system track: the
    /// turn it overlaps most, or the nearest turn within a second when it
    /// overlaps none (Whisper's and the diarizer's boundaries rarely agree
    /// exactly). Nil when no speaker was talking anywhere near.
    static func label(start: Int, end: Int, turns: [SpeakerTurn]) -> String? {
        var overlapByLabel: [String: Int] = [:]
        for t in turns {
            let overlap = min(end, t.end) - max(start, t.start)
            if overlap > 0 { overlapByLabel[t.label, default: 0] += overlap }
        }
        if let best = overlapByLabel.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }
        let nearest = turns.min { gap($0, start, end) < gap($1, start, end) }
        if let nearest, gap(nearest, start, end) <= 1_000 { return nearest.label }
        return nil
    }

    private static func gap(_ t: SpeakerTurn, _ start: Int, _ end: Int) -> Int {
        t.end < start ? start - t.end : (t.start > end ? t.start - end : 0)
    }
}
