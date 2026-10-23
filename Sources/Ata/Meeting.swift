import Foundation

struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recording, pending, transcribing, done, failed
    }

    var id: String // folder name
    var startedAt: Date
    var endedAt: Date?
    var duration: Double?
    var app: String?
    var status: Status
    var error: String?
    /// Every transcription this meeting has had, oldest first. Absent for
    /// meetings transcribed before Ata 2.2.
    var transcriptions: [TranscriptionRecord]? = nil
    /// Engine and model for the next run, when the user picked "Transcribe
    /// again with…". Cleared once that run starts.
    var override: TranscribeOverride? = nil

    var dir: URL { Paths.meetingsDir.appendingPathComponent(id, isDirectory: true) }
    var metaURL: URL { dir.appendingPathComponent("meeting.json") }

    /// Where a new transcript is written. Recordings from Ata 2.0 used a
    /// Portuguese file name, so reading falls back to that one.
    var transcriptURL: URL { dir.appendingPathComponent("transcript.md") }
    private var legacyTranscriptURL: URL { dir.appendingPathComponent("transcricao.md") }

    /// The transcript on disk, whichever name it was written under.
    var existingTranscriptURL: URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: transcriptURL.path) { return transcriptURL }
        if fm.fileExists(atPath: legacyTranscriptURL.path) { return legacyTranscriptURL }
        return nil
    }

    /// Where the recorder writes. Kept audio may later be compressed to m4a,
    /// so anything that reads audio back goes through `micAudioURL` /
    /// `systemAudioURL` instead.
    var micURL: URL { dir.appendingPathComponent("mic.wav") }
    var systemURL: URL { dir.appendingPathComponent("system.wav") }

    /// The transcript as data (segments with speaker labels), for re-rendering.
    var storedTranscriptURL: URL { dir.appendingPathComponent("transcript.json") }
    /// Who spoke in this meeting: diarized speakers, their turns and voices.
    var speakersURL: URL { dir.appendingPathComponent("speakers.json") }

    /// Both tracks mixed into one file, for listening and sharing. Never the
    /// only copy of the audio: the tracks stay for transcribing again.
    var mergedAudioURL: URL { dir.appendingPathComponent("meeting.mp3") }
    var hasMergedAudio: Bool { Paths.fileSize(mergedAudioURL) > 0 }

    /// How loud you and the others were over time, for the player; see `Waveform`.
    var waveformURL: URL { dir.appendingPathComponent("waveform.bin") }

    /// Your own notes, typed in the meeting window.
    var notesURL: URL { dir.appendingPathComponent("notes.md") }

    /// Earlier transcripts, moved aside when the meeting was transcribed again.
    var versionsDir: URL { dir.appendingPathComponent("versions", isDirectory: true) }

    var latestTranscription: TranscriptionRecord? { transcriptions?.last }

    var micAudioURL: URL? { Self.resolveAudio(micURL) }
    var systemAudioURL: URL? { Self.resolveAudio(systemURL) }

    private static func resolveAudio(_ wav: URL) -> URL? {
        if Paths.fileSize(wav) > 44 { return wav }
        let m4a = wav.deletingPathExtension().appendingPathExtension("m4a")
        return Paths.fileSize(m4a) > 0 ? m4a : nil
    }

    var hasAudio: Bool {
        micAudioURL != nil || systemAudioURL != nil
    }

    /// Total size of the audio kept for this meeting, in bytes.
    var audioBytes: Int64 {
        [micAudioURL, systemAudioURL].compactMap { $0 }.reduce(0) { $0 + Paths.fileSize($1) }
            + Paths.fileSize(mergedAudioURL)
    }

    var title: String { app ?? L("Meeting") }

    var subtitle: String {
        var parts = [Self.dayFormatter.string(from: startedAt)]
        if let duration, duration >= 1 {
            let m = Int((duration / 60).rounded())
            parts.append(m < 1 ? L("<1 min") : L("%d min", m))
        }
        return parts.joined(separator: " · ")
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func new(app: String?) throws -> Meeting {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let now = Date()
        var m = Meeting(id: f.string(from: now), startedAt: now, endedAt: nil, duration: nil,
                        app: app, status: .recording, error: nil)
        if let app { m.id += " \(app)" }
        try FileManager.default.createDirectory(at: m.dir, withIntermediateDirectories: true)
        return m
    }
}

/// A one-off choice of engine and model for re-transcribing a meeting.
struct TranscribeOverride: Codable, Equatable {
    var engine: String
    var model: String
}

/// Reads and writes meeting metadata (meeting.json inside each folder).
enum Library {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func save(_ m: Meeting) {
        do {
            try FileManager.default.createDirectory(at: m.dir, withIntermediateDirectories: true)
            try encoder.encode(m).write(to: m.metaURL, options: .atomic)
        } catch {
            NSLog("Ata: could not save \(m.id): \(error)")
        }
    }

    static func loadAll() -> [Meeting] {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.meetingsDir, withIntermediateDirectories: true)
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.meetingsDir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
                  var m = try? decoder.decode(Meeting.self, from: data) else { return nil }
            m.id = dir.lastPathComponent // the folder may have been renamed
            return m
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// One meeting, read fresh from its folder.
    static func load(_ id: String) -> Meeting? {
        let dir = Paths.meetingsDir.appendingPathComponent(id, isDirectory: true)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
              var m = try? decoder.decode(Meeting.self, from: data) else { return nil }
        m.id = id
        return m
    }

    static func trash(_ m: Meeting) {
        try? FileManager.default.trashItem(at: m.dir, resultingItemURL: nil)
    }
}
