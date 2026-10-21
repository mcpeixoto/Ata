import Foundation

enum TranscriberError: LocalizedError {
    case whisperMissing, modelMissing, noAudio
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .whisperMissing: return L("The local transcription engine (whisper.cpp) is not installed.")
        case .modelMissing: return L("The transcription model has not been downloaded yet.")
        case .noAudio: return L("No audio was found for this meeting.")
        case .failed(let log): return L("Whisper failed: %@", log)
        }
    }
}

struct Segment {
    let speaker: String
    let start: Int // ms
    let end: Int   // ms
    let text: String
    /// Word timings, when the engine provides them. Used to split a segment
    /// where the speaker changes, since Whisper's segments ignore turns.
    var words: [Word] = []

    struct Word: Equatable {
        let start: Int // ms
        let end: Int   // ms
        let text: String
    }
}

/// Which backend produces the transcript.
enum Engine: String, CaseIterable {
    /// whisper.cpp on this Mac. Nothing leaves the machine.
    case local
    /// OpenAI's transcription API. Audio is uploaded.
    case openAI = "openai"

    var isLocal: Bool { self == .local }

    static var current: Engine {
        Engine(rawValue: Pref.d.string(forKey: Pref.engine) ?? Engine.local.rawValue) ?? .local
    }
}

/// Everything the transcription job needs, captured when the job is queued so
/// changing a setting mid-run cannot alter a transcript already in flight.
struct TranscribeOptions {
    var engine: Engine
    var myName: String
    var language: String
    var openAIModel: String
    var localModel: String
    var recogniseVoices: Bool = false
    var summarize: Bool
    var summaryModel: String

    /// The model that will actually run, for records and file names.
    var modelID: String { engine.isLocal ? localModel : openAIModel }

    static func current() -> TranscribeOptions {
        TranscribeOptions(
            engine: Engine.current,
            myName: Pref.d.string(forKey: Pref.myName) ?? L("Me"),
            language: Pref.d.string(forKey: Pref.language) ?? "auto",
            openAIModel: Pref.d.string(forKey: Pref.openAIModel) ?? Pref.defaultOpenAIModel,
            localModel: LocalModel.current.id,
            recogniseVoices: Pref.d.bool(forKey: Pref.recogniseVoices),
            summarize: Pref.d.bool(forKey: Pref.summarize),
            summaryModel: Pref.d.string(forKey: Pref.summaryModel) ?? Pref.defaultSummaryModel)
    }

    /// The current settings, with a meeting's one-off engine/model choice on top.
    static func current(for meeting: Meeting) -> TranscribeOptions {
        var o = current()
        guard let override = meeting.override, let engine = Engine(rawValue: override.engine) else { return o }
        o.engine = engine
        if engine.isLocal { o.localModel = override.model } else { o.openAIModel = override.model }
        return o
    }
}

/// The transcript as data: segments with speaker *labels* rather than names,
/// saved as transcript.json next to transcript.md so the Markdown can be
/// redrawn when a voice gets a name, without transcribing again.
struct StoredTranscript: Codable, Equatable {
    struct Line: Codable, Equatable {
        var start: Int // ms
        var end: Int   // ms
        var text: String
        /// `Speakers.me`, `Speakers.others`, or a diarized label like "S1".
        var speaker: String
    }

    var segments: [Line]
    var coarse: Bool
    var summary: String?
    var engine: String
    var model: String

    func save(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> StoredTranscript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StoredTranscript.self, from: data)
    }
}

/// Speaker labels and how they become names.
enum Speakers {
    static let me = "me"
    static let others = "others"

    /// Label → name for one meeting: you, a named voice, "Speaker 2", or "Others".
    static func names(for meeting: Meeting, myName: String) -> (String) -> String {
        let map = MeetingVoices.load(for: meeting)
        let library = map == nil ? nil : VoiceLibrary()
        return { label in
            switch label {
            case me: return myName
            case others: return L("Others")
            default:
                if let id = map?.speakers.first(where: { $0.label == label })?.voiceID,
                   let voice = library?.voice(id) {
                    return voice.displayName
                }
                return L("Speaker %@", String(label.drop { !$0.isNumber }))
            }
        }
    }
}

/// What a finished run produced: its record, and where the transcript it
/// replaced was moved, if there was one.
struct TranscriptionOutcome {
    let record: TranscriptionRecord
    let archivedPrevious: String?
}

/// Picks a language per track when the setting is "Automatic".
///
/// whisper's own auto-detect decides once per file from its first seconds, and
/// in testing it was confidently wrong surprisingly often: UK English came out
/// as Welsh at p 0.89–0.99, and short clips of a quiet microphone track as
/// Russian or Bulgarian. So a detection only counts if it is confident *and*
/// a language the user plausibly speaks.
enum LanguageChoice {
    static let confidence = 0.8

    /// Languages from the user's macOS language list, plus English.
    static var plausible: [String] {
        var codes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        codes.append("en")
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    /// One language per track, in the order given.
    static func pick(_ detections: [(code: String, p: Double)?], plausible: [String]) -> [String] {
        let confident = detections.map { d -> String? in
            guard let d, d.p >= confidence, plausible.contains(d.code) else { return nil }
            return d.code
        }
        // Unsure tracks borrow a confident answer from another track, else the main language.
        let fallback = confident.compactMap { $0 }.first ?? plausible.first ?? "en"
        return confident.map { $0 ?? fallback }
    }
}

/// Runs a transcription end to end: picks the engine per track, merges the two
/// tracks into one timeline, drops microphone echo and writes the Markdown.
enum Transcriber {
    static func transcribe(_ meeting: Meeting, options: TranscribeOptions,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionOutcome {
        let started = Date()

        // Only tracks with at least ~0.5 s of audio are worth sending to an engine.
        var prepared: [(speaker: String, audio: URL, temporary: Bool)] = []
        defer {
            for track in prepared where track.temporary {
                try? FileManager.default.removeItem(at: track.audio)
            }
        }
        for (speaker, source) in [(Speakers.me, meeting.micAudioURL), (Speakers.others, meeting.systemAudioURL)] {
            guard let source, Paths.fileSize(source) > 1_000 else { continue }
            if source.pathExtension.lowercased() == "wav" {
                prepared.append((speaker, source, false))
            } else {
                // The WAV was compressed after an earlier run: decode it back.
                let temp = source.deletingPathExtension().appendingPathExtension("decoded.wav")
                try AudioFiles.decodeToWAV(source, to: temp)
                prepared.append((speaker, temp, true))
            }
        }
        guard !prepared.isEmpty else { throw TranscriberError.noAudio }
        let audioSeconds = prepared.reduce(0) { $0 + WavWriter.duration(of: $1.audio) }

        // The local engine gets an explicit language per track; see LanguageChoice.
        var languages = Array(repeating: options.language, count: prepared.count)
        if options.engine.isLocal, options.language == "auto", let model = LocalModel.find(options.localModel) {
            var detections: [(code: String, p: Double)?] = []
            for track in prepared { detections.append(await LocalEngine.detectLanguage(audio: track.audio, model: model)) }
            languages = LanguageChoice.pick(detections, plausible: LanguageChoice.plausible)
        }

        var segments: [Segment] = []
        var coarse = false
        for (i, track) in prepared.enumerated() {
            let base = Double(i) / Double(prepared.count)
            let span = 1 / Double(prepared.count)
            let step: @Sendable (Double) -> Void = { p in progress(base + p * span) }

            switch options.engine {
            case .local:
                guard let model = LocalModel.find(options.localModel), model.isInstalled else {
                    throw TranscriberError.modelMissing
                }
                segments += try await LocalEngine.transcribe(audio: track.audio, speaker: track.speaker,
                                                             model: model, language: languages[i],
                                                             progress: step)
            case .openAI:
                let result = try await OpenAIEngine.transcribe(audio: track.audio, speaker: track.speaker,
                                                               language: options.language,
                                                               model: options.openAIModel, progress: step)
                segments += result.segments
                coarse = coarse || result.coarse
            }
        }

        // Echo removal compares what both tracks said at the same moment, so it
        // needs real timestamps.
        if !coarse {
            segments = removeEcho(segments, me: Speakers.me)
        }

        if options.recogniseVoices, let diarizer = Diarization.current {
            progress(0.97)
            segments = await recogniseSpeakers(segments, meeting: meeting, diarizer: diarizer,
                                               system: prepared.first { $0.speaker == Speakers.others }?.audio,
                                               mic: prepared.first { $0.speaker == Speakers.me }?.audio)
        }

        var stored = StoredTranscript(
            segments: segments.map { StoredTranscript.Line(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker) },
            coarse: coarse, summary: nil, engine: options.engine.rawValue, model: options.modelID)

        var cost = options.engine.isLocal ? 0 : Pricing.transcription(model: options.openAIModel,
                                                                       seconds: audioSeconds)
        if options.summarize, !segments.isEmpty {
            let draft = render(stored, meeting: meeting, names: Speakers.names(for: meeting, myName: options.myName))
            if let summary = await Summarizer.summarize(markdown: draft, options: options) {
                stored.summary = summary.text
                cost += summary.costUSD
            }
        }
        let md = render(stored, meeting: meeting, names: Speakers.names(for: meeting, myName: options.myName))

        // Never overwrite an earlier transcript: move it into versions/ first.
        let archived = try archivePrevious(of: meeting)
        try md.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)
        try stored.save(to: meeting.storedTranscriptURL)

        let talk = talkTime(segments, me: Speakers.me, coarse: coarse)
        let record = TranscriptionRecord(
            engine: options.engine.rawValue,
            model: options.modelID,
            finishedAt: Date(),
            audioSeconds: audioSeconds,
            processingSeconds: Date().timeIntervalSince(started),
            costUSD: cost,
            words: segments.reduce(0) { $0 + wordCount($1.text) },
            mySpeechSeconds: talk.me,
            othersSpeechSeconds: talk.others,
            archivedAs: nil)
        return TranscriptionOutcome(record: record, archivedPrevious: archived)
    }

    // MARK: - Voices

    /// Splits the "others" lines by speaker and matches each speaker against the
    /// voice library. Anything going wrong here leaves the lines as "others":
    /// a transcript is never lost to voice recognition.
    private static func recogniseSpeakers(_ segments: [Segment], meeting: Meeting, diarizer: Diarizer,
                                          system: URL?, mic: URL?) async -> [Segment] {
        var speakers: [MeetingSpeaker] = []
        var turns: [SpeakerTurn] = []
        var relabelled = segments

        if let system {
            do {
                let found = try await diarizer.diarize(system)
                // Whatever the diarizer calls them, they become S1, S2… in order of first appearance.
                var rename: [String: String] = [:]
                for t in found.turns.sorted(by: { $0.start < $1.start }) where rename[t.label] == nil {
                    rename[t.label] = "S\(rename.count + 1)"
                }
                turns = found.turns.map { SpeakerTurn(start: $0.start, end: $0.end, label: rename[$0.label] ?? $0.label) }
                for (raw, label) in rename {
                    guard let e = found.embeddings[raw] else { continue }
                    let seconds = turns.filter { $0.label == label }.reduce(0.0) { $0 + Double($1.end - $1.start) / 1000 }
                    speakers.append(MeetingSpeaker(label: label, embedding: e, seconds: seconds, voiceID: nil))
                }
                relabelled = segments.flatMap { s -> [Segment] in
                    guard s.speaker == Speakers.others else { return [s] }
                    return SpeakerAssignment.split(s, turns: turns)
                }
            } catch {
                NSLog("Ata: diarization failed: \(error.localizedDescription)")
                return segments
            }
        }
        if let mic, let e = try? await diarizer.embed(mic) {
            speakers.append(MeetingSpeaker(label: Speakers.me, embedding: e, seconds: 0, voiceID: nil))
        }
        guard !speakers.isEmpty else { return relabelled }

        let found = speakers
        let assigned = await MainActor.run { PeopleModel.shared.assign(found, meetingID: meeting.id) }
        try? MeetingVoices(speakers: assigned, turns: turns).save(for: meeting)

        // A few seconds of each new voice, so the user can hear who it is.
        if let system {
            for speaker in assigned where speaker.label != Speakers.me {
                guard let id = speaker.voiceID else { continue }
                let hasSample = await MainActor.run { PeopleModel.shared.voices.first { $0.id == id }?.sample != nil }
                if hasSample { continue }
                if let file = await VoiceSamples.extract(label: speaker.label, turns: turns, from: system, voice: id) {
                    await MainActor.run { PeopleModel.shared.setSample(id, file: file) }
                }
            }
        }
        return relabelled
    }

    // MARK: - Versions

    /// Moves the current transcript to `versions/<date> <model>.md` and returns
    /// that file name, or nil when there was nothing to move.
    static func archivePrevious(of meeting: Meeting) throws -> String? {
        guard let current = meeting.existingTranscriptURL else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: meeting.versionsDir, withIntermediateDirectories: true)

        let previous = meeting.latestTranscription
        let date = previous?.finishedAt
            ?? ((try? fm.attributesOfItem(atPath: current.path)[.modificationDate]) as? Date)
            ?? Date()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var name = "\(f.string(from: date)) \(previous?.model ?? "earlier").md"
        if fm.fileExists(atPath: meeting.versionsDir.appendingPathComponent(name).path) {
            name = "\(f.string(from: date)) \(previous?.model ?? "earlier") \(UUID().uuidString.prefix(4)).md"
        }
        try fm.moveItem(at: current, to: meeting.versionsDir.appendingPathComponent(name))
        return name
    }

    // MARK: - Statistics

    static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    /// Seconds each side spoke. Without timestamps, estimated from words at a
    /// typical 2.5 words a second.
    static func talkTime(_ segments: [Segment], me: String, coarse: Bool) -> (me: Double, others: Double) {
        var mine = 0.0, theirs = 0.0
        for s in segments {
            let seconds = coarse ? Double(wordCount(s.text)) / 2.5 : Double(max(0, s.end - s.start)) / 1000
            if s.speaker == me { mine += seconds } else { theirs += seconds }
        }
        return (mine, theirs)
    }

    static func isNoise(_ t: String) -> Bool {
        let wrapped = (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")"))
            || (t.hasPrefix("*") && t.hasSuffix("*"))
        return wrapped || ["...", "…", "-", "."].contains(t)
    }

    // MARK: - Echo

    /// Without headphones the microphone picks up the other participants, so the
    /// same sentence shows up twice, once attributed to you. Drop microphone
    /// segments that repeat almost word for word what the others said at the same time.
    static func removeEcho(_ segments: [Segment], me: String) -> [Segment] {
        let others = segments.filter { $0.speaker != me }
        guard !others.isEmpty else { return segments }
        return segments.filter { s in
            guard s.speaker == me else { return true }
            let mine = words(s.text)
            guard mine.count >= 3 else {
                return !others.contains { overlaps($0, s) && words($0.text).isSuperset(of: mine) }
            }
            return !others.contains { o in
                guard overlaps(o, s) else { return false }
                let theirs = words(o.text)
                let common = Double(mine.intersection(theirs).count)
                return common / Double(mine.count) > 0.6
            }
        }
    }

    private static func overlaps(_ a: Segment, _ b: Segment) -> Bool {
        a.start < b.end + 1500 && b.start < a.end + 1500
    }

    private static func words(_ t: String) -> Set<String> {
        Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    // MARK: - Markdown

    /// Markdown for a stored transcript, with speaker labels turned into names.
    static func render(_ t: StoredTranscript, meeting: Meeting, names: (String) -> String) -> String {
        var blocks: [StoredTranscript.Line] = []
        for s in t.segments.sorted(by: { $0.start < $1.start }) {
            if let last = blocks.last, last.speaker == s.speaker, s.start - last.end < 2_500 {
                blocks[blocks.count - 1] = .init(start: last.start, end: s.end,
                                                 text: last.text + " " + s.text, speaker: last.speaker)
            } else {
                blocks.append(s)
            }
        }

        let df = DateFormatter()
        // The same language as the rest of the transcript, not the system region.
        df.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        df.dateStyle = .long
        df.timeStyle = .short

        var md = "# \(meeting.title) — \(df.string(from: meeting.startedAt))\n\n"
        var info: [String] = []
        if let d = meeting.duration {
            info.append(L("Duration: %d min", max(1, Int((d / 60).rounded()))))
        }
        var people: [String] = [names(Speakers.me)]
        for b in blocks where !people.contains(names(b.speaker)) { people.append(names(b.speaker)) }
        if people.count == 1 { people.append(names(Speakers.others)) }
        info.append(L("Participants: %@", people.joined(separator: ", ")))
        md += info.joined(separator: " · ") + "\n\n"
        if let summary = t.summary {
            md += "## " + L("Summary") + "\n\n" + summary + "\n\n"
        }
        md += "---\n\n"

        if blocks.isEmpty {
            md += L("_No speech was detected in this recording._") + "\n"
        }
        for b in blocks {
            md += t.coarse
                ? "**\(names(b.speaker)):** \(b.text)\n\n"
                : "**[\(timestamp(b.start))] \(names(b.speaker)):** \(b.text)\n\n"
        }
        md += "---\n"
        md += t.engine == Engine.local.rawValue
            ? "_" + L("Transcribed locally by Ata (%@).", t.model) + "_\n"
            : "_" + L("Transcribed by Ata with OpenAI (%@).", t.model) + "_\n"
        return md
    }

    /// Writes transcript.md again from transcript.json — after a voice is named,
    /// for instance. Same transcription, new names, so nothing is archived.
    static func rerender(_ meeting: Meeting, myName: String) throws {
        guard let stored = StoredTranscript.load(from: meeting.storedTranscriptURL) else { return }
        let md = render(stored, meeting: meeting, names: Speakers.names(for: meeting, myName: myName))
        try md.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)
    }

    private static func timestamp(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
