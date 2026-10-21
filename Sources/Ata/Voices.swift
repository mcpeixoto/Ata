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
    /// Stable "Voice 3" number, given when the voice is first heard, so an
    /// unnamed voice reads the same in every transcript and in the People tab.
    var number: Int? = nil

    var meetings: Int { meetingIDs.count }

    /// The name, or "Voice 3" until it has one.
    var displayName: String { name ?? L("Voice %d", number ?? 0) }
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
    /// voice. Measured with FluidAudio's WeSpeaker embeddings: the same voice
    /// scored 0.95–0.96 across recordings (0.82–0.85 over a phone-quality copy),
    /// different voices 0.02–0.49.
    static var matchThreshold: Float = 0.65

    /// The best match must also beat the second best by this much. A voice that
    /// resembles two known people about equally becomes a new voice rather than
    /// a coin-flip between two names.
    static var requiredLead: Float = 0.1

    /// An unnamed voice is worth asking about once it has turned up in this many meetings.
    static let askAfterMeetings = 2

    let file: URL
    private(set) var voices: [Voice] = []
    /// The file exists but couldn't be read. Saving would replace every voice
    /// with whatever little is in memory, so `save` refuses.
    private(set) var loadFailed = false

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
        guard FileManager.default.fileExists(atPath: file.path) else { voices = []; return }
        guard let data = try? Data(contentsOf: file) else { voices = []; loadFailed = true; return }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.dates.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "bad date \(text)"))
            }
            return date
        }
        if let decoded = try? d.decode([Voice].self, from: data) {
            voices = decoded
        } else {
            voices = []
            loadFailed = true
        }
    }

    func save() throws {
        guard !loadFailed else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.dates.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        // No file-protection class: a transcription finishing while the screen is
        // locked must still be able to read the library back.
        try e.encode(voices).write(to: file, options: .atomic)
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
            let scores = voices.enumerated()
                .map { (v: $0.offset, sim: Self.cosine(speaker.embedding, $0.element.centroid)) }
                .sorted { $0.sim > $1.sim }
            guard let best = scores.first, best.sim >= Self.matchThreshold else { continue }
            if scores.count > 1, best.sim - scores[1].sim < Self.requiredLead { continue }
            candidates.append((s, best.v, best.sim))
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
            let next = (voices.compactMap(\.number).max() ?? 0) + 1
            let voice = Voice(id: UUID(), name: nil, centroid: Self.normalised(speaker.embedding), observations: 1,
                              meetingIDs: [meetingID], sample: nil, firstSeen: date, lastSeen: date,
                              isMe: speaker.label == "me", number: next)
            voices.append(voice)
            result[s].voiceID = voice.id
        }
        return result
    }

    private func learn(voice i: Int, from speaker: MeetingSpeaker, meetingID: String, at date: Date) {
        var v = voices[i]
        // Transcribing the same meeting again must not count it twice.
        if v.meetingIDs.contains(meetingID) { return }
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

    /// A meeting was deleted: it no longer counts for any voice, and voices only
    /// it introduced — never named — go with it. Returns the forgotten voices.
    @discardableResult
    func removeMeeting(_ meetingID: String) -> [Voice] {
        var gone: [Voice] = []
        for i in voices.indices.reversed() where voices[i].meetingIDs.contains(meetingID) {
            voices[i].meetingIDs.removeAll { $0 == meetingID }
            if voices[i].meetingIDs.isEmpty && voices[i].name == nil && !voices[i].isMe {
                gone.append(voices.remove(at: i))
            }
        }
        return gone
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

    /// Splits a system-track segment wherever the speaker changes, using word
    /// timings, and labels each piece. Without word timings the whole segment
    /// goes to whoever spoke most during it.
    static func split(_ s: Segment, turns: [SpeakerTurn]) -> [Segment] {
        let whole = label(start: s.start, end: s.end, turns: turns) ?? s.speaker
        guard !s.words.isEmpty else {
            return [Segment(speaker: whole, start: s.start, end: s.end, text: s.text)]
        }
        // A label per word, from the turn it overlaps.
        var labels: [String] = []
        for w in s.words {
            labels.append(label(start: w.start, end: max(w.end, w.start + 1), turns: turns) ?? labels.last ?? whole)
        }
        snapChangesToPauses(&labels, words: s.words)

        var pieces: [Segment] = []
        var i = 0
        while i < s.words.count {
            var j = i
            while j + 1 < s.words.count && labels[j + 1] == labels[i] { j += 1 }
            let run = Array(s.words[i...j])
            pieces.append(Segment(speaker: labels[i], start: run.first!.start, end: run.last!.end,
                                  text: run.map(\.text).joined(separator: " "), words: run))
            i = j + 1
        }
        return pieces
    }

    /// Whisper's word times run a few hundred milliseconds off the audio, and it
    /// stretches a word over the silence after it, so a change of speaker read
    /// from the turns often lands one word early or late. People change turns at
    /// the end of a sentence or at a pause, so each change moves, within two
    /// words, to the nearest sentence end — or, in unpunctuated text, to the
    /// clearly longest pause.
    static func snapChangesToPauses(_ labels: inout [String], words: [Segment.Word]) {
        guard words.count > 2 else { return }
        func pause(before k: Int) -> Int { max(0, words[k].start - words[k - 1].end) }
        func endsSentence(before k: Int) -> Bool {
            guard let last = words[k - 1].text.last else { return false }
            return ".?!…".contains(last)
        }
        var k = 1
        while k < words.count {
            defer { k += 1 }
            guard labels[k] != labels[k - 1] else { continue }
            let before = labels[k - 1], after = labels[k]
            let window = max(1, k - 2)...min(words.count - 1, k + 2)

            var target: Int?
            if endsSentence(before: k) {
                continue // already right after a sentence end
            } else if let p = window.filter({ endsSentence(before: $0) }).min(by: { abs($0 - k) < abs($1 - k) }) {
                target = p
            } else if pause(before: k) < 150,
                      let best = window.max(by: { pause(before: $0) < pause(before: $1) }),
                      pause(before: best) >= 150, pause(before: best) - pause(before: k) >= 100 {
                target = best
            }
            guard let target, target != k else { continue }

            // Words before `target` belong to the earlier speaker, from `target` on to the
            // later one — only if that touches nothing but the two speakers of this change.
            let range = min(k, target)..<max(k, target)
            guard range.allSatisfy({ labels[$0] == before || labels[$0] == after }) else { continue }
            for m in range { labels[m] = target > k ? before : after }
            k = max(k, target)
        }
    }

    private static func gap(_ t: SpeakerTurn, _ start: Int, _ end: Int) -> Int {
        t.end < start ? start - t.end : (t.start > end ? t.start - end : 0)
    }
}

/// speakers.json in a meeting folder: the diarized speakers of the system
/// track, when they spoke, and which voice each one was matched to.
struct MeetingVoices: Codable, Equatable {
    var speakers: [MeetingSpeaker]
    var turns: [SpeakerTurn]

    static func load(for meeting: Meeting) -> MeetingVoices? {
        guard let data = try? Data(contentsOf: meeting.speakersURL) else { return nil }
        return try? JSONDecoder().decode(MeetingVoices.self, from: data)
    }

    func save(for meeting: Meeting) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: meeting.speakersURL, options: .atomic)
    }
}
