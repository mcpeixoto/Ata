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
    /// You. Learned from the microphone track of a call, or set by hand in the
    /// People tab — the only way on an iPhone, which records one track and so
    /// never has a call's microphone to learn you from.
    var isMe: Bool = false
    /// Stable "Voice 3" number, given when the voice is first heard, so an
    /// unnamed voice reads the same in every transcript and in the People tab.
    var number: Int? = nil
    /// The user said not to ask for a name: the voice stays unnamed and out of "Who's this?".
    var dismissed: Bool? = nil
    /// The user left this voice out of transcripts (a TV, a bot, someone who asked):
    /// its lines are dropped whenever a transcript is drawn, past ones included.
    var excluded: Bool? = nil
    /// The embedding model the centroid came from (`Diarization.embeddingModel`). Nil for
    /// voices learned before Ata 2.6, all of them by `Diarization.untaggedEmbeddingModel`.
    var model: String? = nil
    /// When you last named this voice, or said not to ask or to leave it out. Two
    /// devices that changed it at once keep these from the later edit; see
    /// `VoiceLibrary.merge(versions:)`. Nil until an Ata that records it is the one
    /// that edits the voice.
    var edited: Date? = nil

    /// Now, to the whole second: the library saves dates as ISO 8601 with
    /// milliseconds, so a finer time wouldn't read back equal to itself.
    static func editStamp(_ now: Date = Date()) -> Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    var meetings: Int { meetingIDs.count }

    /// The name, or "Voice 3" until it has one.
    var displayName: String { name ?? L("Voice %d", number ?? 0) }
    var isDismissed: Bool { dismissed == true }
    var isExcluded: Bool { excluded == true }
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
///
/// Stored as one `<id>.json` per voice, beside that voice's sample, so two devices
/// editing different voices never write the same file, and a rename or merge
/// touches only the voices it changes. Before Ata 2.6 the whole library was one
/// `voices.json`; it is read once, written out per voice, and kept as
/// `voices.json.migrated`.
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

    /// Cosine at or above which two fingerprints are taken to be one person
    /// heard twice, rather than two people who sound alike. Stricter than
    /// `matchThreshold`, because this one decides that an ambiguity is not an
    /// ambiguity at all: measured, the same voice scored 0.95–0.96 across
    /// recordings and 0.82–0.85 over a phone-quality copy, while different
    /// voices never passed 0.49.
    static var sameSpeakerThreshold: Float = 0.85

    /// An unnamed voice is worth asking about once it has turned up in this many meetings.
    static let askAfterMeetings = 2

    /// The embedding model new fingerprints come from. Only voices from the same
    /// model are compared: a fingerprint from another model is just other numbers.
    static var model = Diarization.embeddingModel

    static let legacyFileName = "voices.json"

    /// The library as one file, as Ata kept it before 2.6. Only ever read, to migrate.
    let file: URL
    /// Where each voice's `<id>.json` and sample live.
    let directory: URL
    private(set) var voices: [Voice] = []
    /// `voices.json` exists but couldn't be read. Building a new library on top
    /// would hide every voice in it for good, so `save` refuses; voices that have
    /// files of their own still load.
    private(set) var loadFailed = false
    /// Voice files that exist but couldn't be read: damaged, half-synced, or from
    /// a newer Ata. They are never written over or removed.
    private(set) var unreadable: [URL] = []
    /// Voices whose file is still in iCloud: not read, so the main thread never waits
    /// on a download, and, like `unreadable` ones, never written over.
    private(set) var downloading: Set<UUID> = []
    /// Each voice as it was last read or written, so `save` writes only what changed
    /// and removes only files this library itself knew about.
    private var onDisk: [UUID: Voice] = [:]
    /// `voices.json` was read in; it is put aside once every voice in it has its own file.
    private var migrating = false

    /// The library in `directory`: Ata's voices folder unless a test says otherwise.
    init(directory: URL = Paths.voicesDir) {
        self.directory = directory
        self.file = directory.appendingPathComponent(VoiceLibrary.legacyFileName)
        load()
    }

    /// The library that grew out of `file`, a `voices.json` from before 2.6. Its
    /// voices go in the folder it sits in; a file by any other name gets a folder
    /// of its own name beside it, so two such libraries never share one.
    init(file: URL) {
        self.file = file
        self.directory = file.lastPathComponent == VoiceLibrary.legacyFileName
            ? file.deletingLastPathComponent() : file.deletingPathExtension()
        load()
    }

    // MARK: - Persistence

    /// ISO 8601 with fractional seconds, so saving and loading is lossless.
    private static let dates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.dates.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "bad date \(text)"))
            }
            return date
        }
        return d
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.dates.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// `<UUID>.json` is a voice. Samples, `voices.json` and anything else in the folder are not.
    static func voiceID(fileName name: String) -> UUID? {
        guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
        return UUID(uuidString: String(name.dropLast(5)))
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func load() {
        let fm = FileManager.default
        let decoder = Self.decoder()
        var found: [Voice] = []
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
            // On iPhone a voice not downloaded yet is only its placeholder, ".<id>.json.icloud".
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(7))
                if let id = Self.voiceID(fileName: real) {
                    downloading.insert(id)
                    unreadable.append(directory.appendingPathComponent(real))
                }
                continue
            }
            guard let id = Self.voiceID(fileName: name) else { continue }
            let url = directory.appendingPathComponent(name)
            if CloudFiles.readable(url) == nil {
                downloading.insert(id)
                unreadable.append(url)
            } else if let data = try? Data(contentsOf: url), let voice = try? decoder.decode(Voice.self, from: data) {
                found.append(voice)
                onDisk[voice.id] = voice
            } else {
                unreadable.append(url)
            }
        }

        // A library from before 2.6, or one an older Ata wrote since: every voice in
        // it without a file of its own yet joins, then the file is put aside. A
        // migration cut short is finished the same way the next time.
        if fm.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file), let legacy = try? decoder.decode([Voice].self, from: data) {
                let taken = Set(found.map(\.id))
                    .union(unreadable.compactMap { Self.voiceID(fileName: $0.lastPathComponent) })
                found += legacy.filter { !taken.contains($0.id) }
                migrating = true
            } else {
                loadFailed = true
            }
        }
        voices = found.sorted { a, b in
            if a.firstSeen != b.firstSeen { return a.firstSeen < b.firstSeen }
            if (a.number ?? 0) != (b.number ?? 0) { return (a.number ?? 0) < (b.number ?? 0) }
            return a.id.uuidString < b.id.uuidString
        }
        let numbered = numberTheUnnumbered()
        if migrating || numbered {
            do {
                try save()
            } catch {
                NSLog("Ata: could not store the voice library one file per voice: \(error.localizedDescription)")
            }
        }
    }

    /// Gives a number to every voice that has none, and says whether it had to.
    ///
    /// `displayName` is `name ?? "Voice \(number ?? 0)"`, so a voice without a
    /// number reads as "Voice 0" — and *every* such voice reads as "Voice 0". A
    /// library from before numbering has them all, which left "Who's this?"
    /// showing the same name against several different people and no way to tell
    /// which one you were naming.
    ///
    /// Numbers carry on from the highest already in use, in the order the library
    /// is sorted, so the voices that already had one keep it. Two devices doing
    /// this at once can land on different numbers for the same voice; that is a
    /// label, not identity, and `merge(versions:)` settles it by `edited` like
    /// any other field.
    private func numberTheUnnumbered() -> Bool {
        guard voices.contains(where: { $0.number == nil }) else { return false }
        var next = (voices.compactMap(\.number).max() ?? 0) + 1
        for i in voices.indices where voices[i].number == nil {
            voices[i].number = next
            next += 1
        }
        return true
    }

    /// Writes each voice that changed since it was read, atomically, and removes
    /// the files (and samples) of voices that are gone. Voices this library never
    /// read — another device's, say — are left alone.
    func save() throws {
        guard !loadFailed else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = Set(unreadable.map(\.lastPathComponent))
        let encoder = Self.encoder()
        var failure: Error?

        for voice in voices where onDisk[voice.id] != voice {
            let target = url(for: voice.id)
            if blocked.contains(target.lastPathComponent) { continue }
            do {
                // No file-protection class: a transcription finishing while the screen is
                // locked must still be able to read the library back.
                try Coordinated.write(encoder.encode(voice), to: target)
                onDisk[voice.id] = voice
            } catch {
                failure = failure ?? error
            }
        }

        let current = Set(voices.map(\.id))
        let samplesInUse = Set(voices.compactMap(\.sample))
        for (id, gone) in onDisk where !current.contains(id) {
            let target = url(for: id)
            do {
                if fm.fileExists(atPath: target.path) { try Coordinated.remove(target) }
                onDisk[id] = nil
            } catch {
                failure = failure ?? error
                continue
            }
            // A merged voice may have handed its sample on to the voice it joined.
            if let sample = gone.sample, !samplesInUse.contains(sample) {
                try? Coordinated.remove(directory.appendingPathComponent(sample))
            }
        }
        if let failure { throw failure }

        if migrating {
            try putLegacyFileAside()
            migrating = false
        }
    }

    /// `voices.json` becomes `voices.json.migrated`: kept, never deleted.
    private func putLegacyFileAside() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }  // another library got there first
        var aside = file.appendingPathExtension("migrated")
        var n = 2
        while fm.fileExists(atPath: aside.path) {
            aside = file.appendingPathExtension("migrated-\(n)")
            n += 1
        }
        try fm.moveItem(at: file, to: aside)
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
                .filter { Self.isCurrent($0.element) }
                .map { (v: $0.offset, sim: Self.cosine(speaker.embedding, $0.element.centroid)) }
                .sorted { $0.sim > $1.sim }
            guard let best = scores.first, best.sim >= Self.matchThreshold else { continue }
            // The lead rule is here to stop a coin-flip between two different
            // people. Two library voices that sound like *each other* are not two
            // people: the diarizer hears one person as two often enough that the
            // library holds duplicates of them, and asking for a lead between a
            // voice and its own copy matched neither — it minted a third copy, and
            // did it again every meeting, so a name the user had given stopped
            // being used and "Who's this?" never filled up.
            if scores.count > 1, best.sim - scores[1].sim < Self.requiredLead,
               Self.cosine(voices[best.v].centroid, voices[scores[1].v].centroid) < Self.matchThreshold {
                continue
            }
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

        // Two speakers of one meeting never share a voice: the diarizer says they
        // are two people, and that invariant is what keeps a conversation from
        // collapsing into one name. When it is wrong — one person heard as two —
        // the library ends up with a near-identical pair, which the lead rule
        // above now recognises as one person rather than minting a third copy of
        // them every meeting after. "Same person as" merges the pair for good.
        for (s, speaker) in speakers.enumerated() where !takenSpeakers.contains(s) && !speaker.embedding.isEmpty {
            let next = (voices.compactMap(\.number).max() ?? 0) + 1
            let voice = Voice(id: UUID(), name: nil, centroid: Self.normalised(speaker.embedding), observations: 1,
                              meetingIDs: [meetingID], sample: nil, firstSeen: date, lastSeen: date,
                              isMe: speaker.label == "me", number: next, model: Self.model)
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
        v.model = Self.model
        // Only an unnamed voice, or one already yours, is learned as you. Without
        // headphones the microphone carries the others' voices back through the
        // speaker, and echo removal is best-effort; one bad call would otherwise
        // put "this is you" on a colleague you had named, for good.
        if speaker.label == "me", v.name == nil || v.isMe { v.isMe = true }
        voices[i] = v
    }

    /// The model a voice's fingerprint came from; untagged ones are from before 2.6.
    static func embeddingModel(of voice: Voice) -> String {
        voice.model ?? Diarization.untaggedEmbeddingModel
    }

    /// Whether a voice can be compared with fingerprints made now.
    static func isCurrent(_ voice: Voice) -> Bool { embeddingModel(of: voice) == model }

    /// Your own voice, as learned from the microphone of calls: what an in-person
    /// meeting looks for among the people in the room.
    var myFingerprints: [[Float]] {
        voices.filter { $0.isMe && Self.isCurrent($0) }.map(\.centroid)
    }

    // MARK: - Editing

    func voice(_ id: UUID?) -> Voice? { id.flatMap { id in voices.first { $0.id == id } } }

    func rename(_ id: UUID, to name: String?) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        voices[i].name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        voices[i].edited = Voice.editStamp()
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
        var merged = b
        if Self.embeddingModel(of: a) == Self.embeddingModel(of: b) {
            let total = Float(a.observations + b.observations)
            merged.centroid = Self.normalised(zip(a.centroid, b.centroid).map {
                ($0 * Float(a.observations) + $1 * Float(b.observations)) / total
            })
            merged.observations = a.observations + b.observations
            merged.model = b.model ?? a.model
        } else {
            // Fingerprints from two models can't be averaged: keep the one still compared.
            let kept = Self.isCurrent(a) ? a : b
            merged.centroid = kept.centroid
            merged.observations = kept.observations
            merged.model = kept.model
        }
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

    /// Never ask for this voice's name (or ask again, with `false`).
    func setDismissed(_ id: UUID, _ on: Bool) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[i].dismissed = on ? true : nil
        voices[i].edited = Voice.editStamp()
    }

    /// Leave this voice's lines out of every transcript (or put them back).
    func setExcluded(_ id: UUID, _ on: Bool) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        voices[i].excluded = on ? true : nil
        voices[i].edited = Voice.editStamp()
    }

    /// Your voice, read into the microphone on purpose.
    ///
    /// A recording you made of yourself outranks anything the pipeline guessed:
    /// it is the one fingerprint of you that cannot be a mistake. If a voice
    /// already in the library sounds like it, that is you heard in past meetings
    /// and it is marked rather than duplicated — so those meetings' speaker
    /// becomes you too. Otherwise a new voice is added.
    ///
    /// Returns the voice that is now yours.
    @discardableResult
    func enrolMe(embedding: [Float], sample: String? = nil, at date: Date = Date()) -> Voice {
        let fingerprint = Self.normalised(embedding)
        let best = voices.enumerated()
            .filter { Self.isCurrent($0.element) }
            .map { (v: $0.offset, sim: Self.cosine(fingerprint, $0.element.centroid)) }
            .max { $0.sim < $1.sim }

        // Every by-hand mark is cleared: this is now the voice that is you.
        for j in voices.indices where voices[j].isMe && voices[j].edited != nil {
            voices[j].isMe = false
            voices[j].edited = Voice.editStamp(date)
        }

        if let best, best.sim >= Self.matchThreshold {
            var v = voices[best.v]
            let n = Float(v.observations)
            v.centroid = Self.normalised(zip(v.centroid, fingerprint).map { ($0 * n + $1) / (n + 1) })
            v.observations += 1
            v.isMe = true
            v.lastSeen = max(v.lastSeen, date)
            v.model = Self.model
            if v.sample == nil { v.sample = sample }
            v.edited = Voice.editStamp(date)
            voices[best.v] = v
            return v
        }

        let next = (voices.compactMap(\.number).max() ?? 0) + 1
        let voice = Voice(id: UUID(), name: nil, centroid: fingerprint, observations: 1, meetingIDs: [],
                          sample: sample, firstSeen: date, lastSeen: date, isMe: true, number: next,
                          model: Self.model, edited: Voice.editStamp(date))
        voices.append(voice)
        return voice
    }

    /// "This voice is me", or no longer me. One voice at a time is yours by hand:
    /// marking a second clears the first, so a mistaken tap can't leave two people
    /// as you. Voices learned as you from the microphone of a call are left alone.
    func setMe(_ id: UUID, _ on: Bool) {
        guard let i = voices.firstIndex(where: { $0.id == id }) else { return }
        if on {
            for j in voices.indices where j != i && voices[j].isMe && voices[j].edited != nil {
                voices[j].isMe = false
                voices[j].edited = Voice.editStamp()
            }
        }
        voices[i].isMe = on
        voices[i].edited = Voice.editStamp()
    }

    // MARK: - Two devices, one voice

    /// One version of a voice file that two devices changed before either saw the
    /// other's change, and when that version was saved.
    struct Version {
        var voice: Voice
        var modified: Date?
    }

    /// The versions of one voice as one. What you set by hand (the name, "don't ask",
    /// "leave out") comes from the version edited last, or, when none says, the newest
    /// name there is; so a name given on one device survives a fingerprint learned on
    /// the other. What was learned is combined: every meeting, the fingerprint averaged
    /// by observations as `merge(_:into:)` does (the versions share their history, so
    /// the count is the larger one, not the sum), the earliest and latest sighting.
    /// Nil when the versions aren't all of one voice.
    static func merge(versions: [Version]) -> Voice? {
        guard let first = versions.first, versions.allSatisfy({ $0.voice.id == first.voice.id }) else { return nil }
        // Newest first; a tie keeps the given order, this device's version first.
        let ordered = versions.enumerated().sorted { a, b in
            let x = a.element.modified ?? .distantPast, y = b.element.modified ?? .distantPast
            return x != y ? x > y : a.offset < b.offset
        }.map { $0.element.voice }
        let newest = ordered[0]
        var merged = newest

        let byHand = ordered.dropFirst().reduce(newest) { best, v in
            (v.edited ?? .distantPast) > (best.edited ?? .distantPast) ? v : best
        }
        merged.name = byHand.edited == nil ? ordered.compactMap(\.name).first : byHand.name
        merged.dismissed = byHand.dismissed
        merged.excluded = byHand.excluded
        merged.edited = byHand.edited

        // The fingerprint that knows most, averaged with the others from the same model.
        let learned = ordered.dropFirst().reduce(newest) { best, v in v.observations > best.observations ? v : best }
        let model = embeddingModel(of: learned)
        let alike = ordered.filter { embeddingModel(of: $0) == model && $0.centroid.count == learned.centroid.count }
        let total = Float(alike.reduce(0) { $0 + max(1, $1.observations) })
        var centroid = [Float](repeating: 0, count: learned.centroid.count)
        for v in alike {
            let weight = Float(max(1, v.observations)) / total
            for i in centroid.indices { centroid[i] += v.centroid[i] * weight }
        }
        merged.centroid = normalised(centroid)
        merged.observations = learned.observations
        merged.model = learned.model

        merged.meetingIDs = Array(Set(ordered.flatMap(\.meetingIDs))).sorted()
        merged.sample = ordered.compactMap(\.sample).first
        merged.firstSeen = ordered.map(\.firstSeen).min() ?? newest.firstSeen
        merged.lastSeen = ordered.map(\.lastSeen).max() ?? newest.lastSeen
        // Learned from a call, "me" only ever turns on, so the union is right. Set by
        // hand it can also turn off, and then the later edit decides — as a name does.
        merged.isMe = byHand.edited == nil ? ordered.contains(where: \.isMe) : byHand.isMe
        merged.number = newest.number ?? ordered.compactMap(\.number).first
        return merged
    }

    func forgetAll() {
        voices = []
    }

    /// Unnamed voices heard often enough to be worth naming, most frequent first.
    var worthAsking: [Voice] {
        voices.filter { $0.name == nil && !$0.isMe && !$0.isDismissed && !$0.isExcluded
            && $0.meetings >= Self.askAfterMeetings }
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

/// A stretch of time in which one speaker of a diarized track was talking: the
/// system track of a call, or the microphone of a meeting in the room.
struct SpeakerTurn: Codable, Equatable {
    var start: Int // ms
    var end: Int   // ms
    var label: String
}

enum SpeakerAssignment {
    /// The speaker label for a transcript segment of a diarized track: the
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

    /// Splits a segment of a diarized track wherever the speaker changes, using word
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
/// track (or, in person, the microphone), when they spoke, and which voice
/// each one was matched to.
struct MeetingVoices: Codable, Equatable {
    var speakers: [MeetingSpeaker]
    var turns: [SpeakerTurn]

    /// Nil, too, while speakers.json is still in iCloud: reading it would wait for the download.
    static func load(for meeting: Meeting) -> MeetingVoices? {
        guard let file = CloudFiles.readable(meeting.speakersURL), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(MeetingVoices.self, from: data)
    }

    func save(for meeting: Meeting) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Coordinated.write(e.encode(self), to: meeting.speakersURL)
    }
}

/// Which track tells the speakers apart.
enum SpeakerRoute: Equatable {
    /// A call: the system track is diarized, and the microphone is you.
    case call
    /// Everyone in one room on one microphone: the microphone is diarized, and
    /// you are found among its speakers.
    case inPerson
    /// Nothing to tell anyone apart in.
    case nobody

    /// A system track with less sound than this is not a call. A Mac records one
    /// in every meeting, silent while nothing plays, and a notification chime or
    /// two must not turn a conversation in the room into a call.
    static let minimumSystemSeconds = 3.0

    /// And it must be this much of the recording. Three seconds alone was enough
    /// to call an hour in a meeting room a call — one played video, one ringtone,
    /// one demo — and down that path the microphone is the whole room: everyone
    /// in it got your name, and the loudest of them was learned as your voice.
    /// The other side of a real call speaks for far more of it than a twentieth.
    static let minimumSystemShare = 0.05

    /// Louder than −50 dBFS counts as sound; a process tap is digital silence
    /// while nothing plays.
    static let audibleLevel = Waveform.level(rms: pow(10, -50.0 / 20))

    /// `systemLevels` is the system track's waveform lane (`Waveform.levels`), nil
    /// when there was no system track worth transcribing. `systemUnreadable` says
    /// there was one but its levels could not be read.
    static func choose(systemLevels: [UInt8]?, hasMic: Bool, systemUnreadable: Bool = false) -> SpeakerRoute {
        if let systemLevels, isCall(systemLevels) { return .call }
        // A track whose levels wouldn't read is a track all the same. Calling it
        // silence sent real calls down the in-person path, where the microphone —
        // your voice with the others' echo over it — was taken for a room.
        if systemUnreadable { return .call }
        return hasMic ? .inPerson : .nobody
    }

    /// Enough sound, for long enough and for enough of the recording, to be the
    /// other side of a call rather than something that played in the room.
    static func isCall(_ levels: [UInt8]) -> Bool {
        let heard = audibleSeconds(levels)
        let whole = Double(levels.count) * Double(Waveform.bucketMs) / 1000
        return heard >= max(minimumSystemSeconds, whole * minimumSystemShare)
    }

    static func audibleSeconds(_ levels: [UInt8]) -> Double {
        Double(levels.filter { $0 >= audibleLevel }.count) * Double(Waveform.bucketMs) / 1000
    }
}

/// Telling people apart on one microphone, and finding you among them.
enum InPerson {
    /// One speaker the diarizer found on the microphone.
    struct Cluster: Equatable {
        var label: String
        /// Nil for a speaker with too little speech to fingerprint.
        var embedding: [Float]?
        var seconds: Double
    }

    /// Which cluster is you, and how Ata knows.
    struct Me: Equatable {
        var label: String
        /// Matched to your fingerprint. Otherwise it is a guess, and a guess is
        /// never learned as your voice: one wrong guess would make someone else "you".
        var recognised: Bool
    }

    static func clusters(_ turns: [SpeakerTurn], embeddings: [String: [Float]]) -> [Cluster] {
        Dictionary(grouping: turns, by: \.label)
            .map { entry in
                Cluster(label: entry.key, embedding: embeddings[entry.key],
                        seconds: entry.value.reduce(0.0) { $0 + Double($1.end - $1.start) / 1000 })
            }
            .sorted { $0.label < $1.label }
    }

    /// You are the cluster that matches your fingerprint by the library's own
    /// rule: at least `VoiceLibrary.matchThreshold`, and `requiredLead` ahead of
    /// the next cluster. With no fingerprint yet, or no clear match, you are
    /// whoever spoke most, since the microphone recording is usually yours and
    /// nearest to you. Nil only when nobody spoke.
    static func me(among clusters: [Cluster], fingerprints: [[Float]]) -> Me? {
        if !fingerprints.isEmpty {
            let scores = clusters.compactMap { c -> (label: String, embedding: [Float], similarity: Float)? in
                guard let e = c.embedding, !e.isEmpty else { return nil }
                return (c.label, e, fingerprints.map { VoiceLibrary.cosine(e, $0) }.max() ?? 0)
            }.sorted { $0.similarity > $1.similarity }
            if let best = scores.first, best.similarity >= VoiceLibrary.matchThreshold {
                if scores.count < 2 || best.similarity - scores[1].similarity >= VoiceLibrary.requiredLead {
                    return Me(label: best.label, recognised: true)
                }
                // The lead rule separates two different people. When the two best
                // candidates sound like *each other*, they are one person the
                // diarizer split in two and either of them is you — so the answer
                // is "the longer one", not "I don't know". Giving up here handed
                // the meeting back to a guess, and the guess then put your name on
                // whoever had talked most, which could be somebody else entirely.
                if VoiceLibrary.cosine(scores[0].embedding, scores[1].embedding)
                    >= VoiceLibrary.sameSpeakerThreshold {
                    let tied = Set([scores[0].label, scores[1].label])
                    let longest = clusters.filter { tied.contains($0.label) }
                        .max { $0.seconds < $1.seconds }
                    return Me(label: longest?.label ?? best.label, recognised: true)
                }
            }
        }
        let most = clusters.max { a, b in a.seconds < b.seconds || (a.seconds == b.seconds && a.label > b.label) }
        return most.map { Me(label: $0.label, recognised: false) }
    }

    /// Diarizer label → transcript label: `Speakers.me` for you, and S1, S2… for
    /// everyone else in order of first appearance, as on the system track.
    static func labels(_ turns: [SpeakerTurn], me: String?) -> [String: String] {
        var out: [String: String] = [:]
        if let me { out[me] = Speakers.me }
        var n = 0
        for t in turns.sorted(by: { $0.start < $1.start }) where out[t.label] == nil {
            n += 1
            out[t.label] = "S\(n)"
        }
        return out
    }

    /// The label a guessed "you" should hand over to.
    ///
    /// Ata falls back to "whoever spoke longest is you" when it has no
    /// fingerprint of you or no clear match. If the library then recognises a
    /// *different* speaker of the same meeting as you, the library is right and
    /// the guess is not: the two labels swap, so the guess becomes an ordinary
    /// participant instead of leaving two people under your name. Nil when the
    /// guess stands — Ata recognised you outright, or nothing it found is you.
    static func correction(guessed: Bool, assigned: [MeetingSpeaker], myVoices: Set<UUID>) -> String? {
        guard guessed else { return nil }
        return assigned.first { s in
            s.label != Speakers.guessedMe && s.voiceID.map(myVoices.contains) == true
        }?.label
    }

    /// Labels the library matched to your own voice after all: the diarizer
    /// sometimes hears one person as two.
    static func alsoMe(_ assigned: [MeetingSpeaker], myVoices: Set<UUID>) -> Set<String> {
        Set(assigned.compactMap { s -> String? in
            guard s.label != Speakers.me, let id = s.voiceID, myVoices.contains(id) else { return nil }
            return s.label
        })
    }
}
