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
    /// The device that recorded or imported it. Absent in meetings from before
    /// Ata 2.6, which were all made on the Mac that has them: nil means this device.
    var origin: DeviceRef? = nil
    /// Which device is transcribing it, so two devices sharing the folder never
    /// both do. Cleared when the run ends.
    var claim: Claim? = nil
    /// Moments marked while recording.
    /// The calendar event this meeting was recorded for, when it started from
    /// one. Its title names the folder, the window and the transcript, and its
    /// attendees are the names "Who's this?" offers for a voice heard here.
    /// Nil for every meeting from before Ata 2.11, and for every one started by
    /// hand, by the hotkey, by meeting detection or by an import.
    var event: MeetingEvent? = nil
    var bookmarks: [Bookmark]? = nil
    /// The system track was the 2.11 double-speed corruption, and Ata has
    /// repaired it. The meeting window and the transcript say so. Nil on every
    /// meeting that was not.
    var systemAudioCorrupt: Bool? = nil
    /// The recording used the laptop's built-in microphone, or the only input
    /// device there was. Everyone in the room is on that one track, so it is
    /// diarized instead of being labelled as one person. Nil before Ata 3.0.5,
    /// which decides from the system track alone.
    var soloMicrophone: Bool? = nil
    /// Never written: set on a meeting whose meeting.json is still in iCloud, listed
    /// from its folder name until the file arrives. See `Library.placeholder`.
    var cloudPlaceholder: Bool? = nil

    var isPlaceholder: Bool { cloudPlaceholder == true }

    /// In the meetings folder, or in this device's staging folder while it is
    /// being recorded (and, if moving it failed, until the next launch moves it).
    var dir: URL { Library.folder(for: id) }
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

    /// Both names a transcript may have, there or not.
    var transcriptFiles: [URL] { [transcriptURL, legacyTranscriptURL] }

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
    var hasMergedAudio: Bool {
        Paths.fileSize(mergedAudioURL) > 0 || (CloudLibrary.isActive && CloudFiles.isPlaceholder(mergedAudioURL))
    }

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
        if Paths.fileSize(m4a) > 0 { return m4a }
        // Still in iCloud: the meeting's audio all the same, downloaded when it is
        // played or transcribed.
        guard CloudLibrary.isActive else { return nil }
        if CloudFiles.isPlaceholder(wav) { return wav }
        return CloudFiles.isPlaceholder(m4a) ? m4a : nil
    }

    var hasAudio: Bool {
        micAudioURL != nil || systemAudioURL != nil
    }

    /// The original system track the 2.11 repair kept beside the fixed one
    /// (`system.corrupted.wav` / `.m4a`), whichever are there. Audio all the
    /// same: it counts toward storage, and goes when the user's settings say
    /// the meeting's audio goes.
    var repairBackupURLs: [URL] {
        ["system.corrupted.wav", "system.corrupted.m4a"].map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Every audio file kept for this meeting, for storage and retention.
    var keptAudioFiles: [URL] {
        [micAudioURL, systemAudioURL].compactMap { $0 } + [mergedAudioURL] + repairBackupURLs
    }

    /// What "don't keep audio" removes once a transcript has succeeded.
    var audioFilesToDiscard: [URL] {
        [micURL, systemURL, mergedAudioURL] + repairBackupURLs
    }

    /// Total size of the audio kept for this meeting, in bytes.
    var audioBytes: Int64 {
        keptAudioFiles.reduce(0) { $0 + Paths.fileSize($1) }
    }

    /// What this meeting is called: the calendar event's title when it came from
    /// one, otherwise the app that was on the microphone.
    ///
    /// `Insights` must not group by this — see the comment where it groups.
    var title: String { event?.title ?? app ?? L("Meeting") }

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

    /// A new meeting folder, made by this device. `staged` puts it in the
    /// staging folder, for a recording or an import still being written.
    static func new(app: String?, event: MeetingEvent? = nil,
                    at date: Date = Date(), staged: Bool = false) throws -> Meeting {
        // Through FolderNames, not an inline formatter. An event's title is the
        // user's own text and may hold a slash, a colon, a newline or two hundred
        // characters, none of which may reach a path component — and having two
        // formatters is how one of them came to forget the sanitising.
        let name = FolderNames.name(startedAt: date, app: app, event: event)
        let id = try Library.makeFolder(named: name, staged: staged)
        var m = Meeting(id: id, startedAt: date, endedAt: nil, duration: nil,
                        app: app, status: .recording, error: nil)
        m.origin = Device.current
        m.event = event
        return m
    }

    /// A new staged meeting folder for an import (an audio file, a Watch
    /// recording), marked as one until `Library.finishImport` has it whole. A
    /// launch after a crash then knows an import cut off mid-decode, whose source
    /// is still where it was, from a recording cut short, which is all there is.
    static func newImport(app: String?, at date: Date) throws -> Meeting {
        let m = try new(app: app, at: date, staged: true)
        do {
            try Data().write(to: m.dir.appendingPathComponent(Library.importMarker))
        } catch {
            try? FileManager.default.removeItem(at: m.dir)
            throw error
        }
        return m
    }

    // MARK: Devices

    /// Made on this device, or before Ata knew about devices.
    var isMine: Bool { belongs(to: Device.current) }

    /// A meeting that names no device is from before Ata 2.6, and this device's only
    /// while the library is on it. In iCloud it could be the other device's: copying a
    /// library in names its device (`CloudMigration.stampOrigin`), so there it is
    /// nobody's to compress, delete or recover.
    func belongs(to device: DeviceRef) -> Bool {
        guard let origin else { return !CloudLibrary.isActive }
        return origin.id == device.id
    }

    /// Whether `device` may transcribe it now: nobody has it, `device` already
    /// has it, or whoever had it stopped renewing the claim while it still
    /// waited. A device that is transcribing renews its claim every few minutes.
    func canClaim(now: Date = Date(), by device: DeviceRef = Device.current) -> Bool {
        guard let claim, claim.device.id != device.id else { return true }
        return (status == .pending || status == .transcribing)
            && now.timeIntervalSince(claim.at) > Claim.timeout
    }

    /// Waiting for a transcript that `device` may make now. A meeting another
    /// device left mid-transcription counts once its claim has gone stale.
    func awaitsTranscript(now: Date = Date(), by device: DeviceRef = Device.current) -> Bool {
        switch status {
        case .pending:
            return canClaim(now: now, by: device)
        case .transcribing:
            guard let claim, claim.device.id != device.id else { return false }
            return canClaim(now: now, by: device)
        default:
            return false
        }
    }

    /// `device` holds the claim: nobody has taken the meeting over from it.
    func isClaimed(by device: DeviceRef = Device.current) -> Bool {
        claim?.device.id == device.id
    }

    /// Whether a run `device` started may end by saving `status`, with meeting.json
    /// as `fresh` has it now (nil: deleted meanwhile, never brought back). Only while
    /// the claim is still the run's: a device that took over a stale claim owns the
    /// meeting now, and its transcript is never replaced by an older one or by a
    /// failure. A meeting.json still in iCloud can't tell, and leaves it as it was.
    static func mayFinish(_ status: Status, over fresh: Meeting?, by device: DeviceRef) -> Bool {
        guard let fresh else { return false }
        if fresh.isPlaceholder { return true }
        if fresh.status == .done, status != .done { return false }
        return fresh.isClaimed(by: device)
    }

    /// What a meeting left behind by a crash, power loss or force quit becomes
    /// on the next launch, or nil to leave it alone. Only this device's own
    /// work is picked up: another device's "recording" may be recording right
    /// now, and its "transcribing" may be running right now.
    func recovered(by device: DeviceRef = Device.current) -> Meeting? {
        var m = self
        switch status {
        case .recording:
            guard belongs(to: device) else { return nil }
            let d1 = WavWriter.repairHeader(m.micURL)
            let d2 = WavWriter.repairHeader(m.systemURL)
            m.duration = max(d1, d2)
            m.endedAt = m.endedAt ?? m.startedAt.addingTimeInterval(max(d1, d2))
            m.status = m.hasAudio ? .pending : .failed
            if !m.hasAudio { m.error = L("Empty recording") }
            return m
        case .transcribing:
            let mine = claim.map { $0.device.id == device.id } ?? belongs(to: device)
            guard mine else { return nil }
            // The claim stays: the job is this device's to finish.
            m.status = .pending
            return m
        default:
            return nil
        }
    }
}

/// A device saying it is transcribing a meeting, and since when.
struct Claim: Codable, Equatable {
    var device: DeviceRef
    var at: Date

    /// After this long without being renewed, another device may take over.
    static let timeout: TimeInterval = 30 * 60
}

/// A moment marked while recording, in milliseconds from the start.
struct Bookmark: Codable, Equatable, Identifiable {
    var id: UUID
    var ms: Int
    var note: String?

    init(id: UUID = UUID(), ms: Int, note: String? = nil) {
        self.id = id
        self.ms = ms
        self.note = note
    }

    /// The line a mark points at, from lines sorted by start: the one being
    /// said at that moment, otherwise the closest one. A mark usually comes
    /// just after the words that prompted it, so the line before wins a near tie.
    static func nearest(to ms: Int, starts: [Int], ends: [Int]) -> Int? {
        guard !starts.isEmpty, starts.count == ends.count else { return nil }
        if let during = starts.indices.last(where: { starts[$0] <= ms && ms <= ends[$0] }) { return during }
        let before = starts.indices.last(where: { ends[$0] < ms })
        let after = starts.indices.first(where: { starts[$0] > ms })
        switch (before, after) {
        case let (b?, a?):
            return ms - ends[b] <= starts[a] - ms + 3_000 ? b : a
        case let (b?, nil):
            return b
        case let (nil, a?):
            return a
        case (nil, nil):
            return nil
        }
    }
}

/// A one-off choice of engine and model for re-transcribing a meeting.
struct TranscribeOverride: Codable, Equatable {
    var engine: String
    var model: String
    /// The language for this one run ("pt", "en"…), when the user asked for a
    /// language rather than the one in Settings. Nil means the setting.
    var language: String? = nil
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
        // A stand-in for a meeting.json still in iCloud: writing it would replace the real one.
        guard !m.isPlaceholder else { return }
        do {
            try FileManager.default.createDirectory(at: m.dir, withIntermediateDirectories: true)
            try Coordinated.write(encoder.encode(m), to: m.metaURL)
        } catch {
            NSLog("Ata: could not save \(m.id): \(error)")
        }
    }

    /// Every meeting: the meetings folder, plus whatever is still in staging
    /// (the recording in progress, or one that could not be moved yet).
    static func loadAll() -> [Meeting] {
        let fm = FileManager.default
        try? CloudLibrary.createFolder(Paths.meetingsDir)
        let staged = stagedIDs()
        let dirs = (try? fm.contentsOfDirectory(at: Paths.meetingsDir, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        // A folder in both places is a move that didn't finish: the staged one is in use.
        let ids = staged + dirs.map(\.lastPathComponent).filter { !staged.contains($0) }
        return ids.compactMap { load($0) }.sorted { $0.startedAt > $1.startedAt }
    }

    /// One meeting, read fresh from its folder.
    static func load(_ id: String) -> Meeting? {
        let dir = folder(for: id)
        let meta = dir.appendingPathComponent("meeting.json")
        // Synced from another device, not downloaded yet: listed as in iCloud, not left out.
        // Reading a Mac's dataless file would wait for the download, on the main thread.
        if CloudLibrary.isActive, CloudFiles.state(of: meta) == .inCloud {
            CloudFiles.requestDownload(meta)
            return placeholder(id: id, in: dir)
        }
        guard let data = try? Data(contentsOf: meta),
              var m = try? decoder.decode(Meeting.self, from: data) else { return nil }
        m.id = id // the folder may have been renamed
        return m
    }

    /// A meeting whose meeting.json is still in iCloud, as far as its folder tells:
    /// the date and app from its name. Its device is unknown, so nothing treats it
    /// as this device's to recover, prune or transcribe, and `save` never writes it.
    static func placeholder(id: String, in dir: URL) -> Meeting {
        let named = folderName(id)
        let created = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        var m = Meeting(id: id, startedAt: named.date ?? created ?? .distantPast, endedAt: nil, duration: nil,
                        app: named.app, status: .done, error: nil)
        m.origin = DeviceRef(id: "", name: "")
        m.cloudPlaceholder = true
        return m
    }

    /// "2026-10-23 14.02.05 Zoom" is its date and "Zoom".
    ///
    /// Since 2.11 that second part is the calendar event's title for a meeting
    /// that came from one ("Weekly sync"), because the folder is named after
    /// whatever the meeting is called. A folder name cannot say which it is, so
    /// `placeholder` puts it in `app`: a meeting still on its way down from
    /// iCloud then reads right in the list, and its event arrives with
    /// meeting.json. `Insights` skips placeholders, so this never reaches the
    /// "Where" chart. It also means the folder name is the durable copy of a
    /// meeting's title — `load` already trusts the folder over the JSON.
    static func folderName(_ id: String) -> (date: Date?, app: String?) {
        guard id.count >= 19, let date = folderDates.date(from: String(id.prefix(19))) else { return (nil, nil) }
        let rest = id.dropFirst(19).trimmingCharacters(in: .whitespaces)
        return (date, rest.isEmpty ? nil : rest)
    }

    private static let folderDates: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    // MARK: Staging

    /// Where the meeting `id` lives: in staging while that folder exists, in
    /// the meetings folder otherwise. Only looks; creates nothing.
    static func folder(for id: String) -> URL {
        let staged = Device.stagingDir.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: staged.path) { return staged }
        return Paths.meetingsDir.appendingPathComponent(id, isDirectory: true)
    }

    /// Meeting folders waiting in this device's staging folder.
    static func stagedIDs() -> [String] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Device.stagingDir, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// `name`, or `name 2`, `name 3`… when a meeting by that name exists in
    /// either folder, so a new meeting never writes into another one's folder.
    static func unusedID(_ name: String) -> String {
        let fm = FileManager.default
        func taken(_ id: String) -> Bool {
            fm.fileExists(atPath: Device.stagingDir.appendingPathComponent(id).path)
                || fm.fileExists(atPath: Paths.meetingsDir.appendingPathComponent(id).path)
        }
        var id = name
        var n = 2
        while taken(id) {
            id = "\(name) \(n)"
            n += 1
        }
        return id
    }

    /// Makes a new, empty meeting folder, in staging or in the meetings folder,
    /// and returns its id: `name`, or the next free `name 2`, `name 3`… Looking
    /// and making are two steps, so the folder itself is made without
    /// `withIntermediateDirectories`: if another import made it in between, that
    /// one fails here and the next name is tried. Two meetings never share a folder.
    static func makeFolder(named name: String, staged: Bool) throws -> String {
        let fm = FileManager.default
        let parent = staged ? Device.stagingDir : Paths.meetingsDir
        try CloudLibrary.createFolder(parent)
        var id = unusedID(name)
        var n = 2
        while true {
            let dir = parent.appendingPathComponent(id, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
                return id
            } catch {
                // Anything but "it's there now" is a real failure.
                guard fm.fileExists(atPath: dir.path) else { throw error }
            }
            repeat {
                id = "\(name) \(n)"
                n += 1
            } while fm.fileExists(atPath: Device.stagingDir.appendingPathComponent(id).path)
                || fm.fileExists(atPath: Paths.meetingsDir.appendingPathComponent(id).path)
        }
    }

    /// Moves a meeting that has stopped recording out of staging and into the
    /// meetings folder, and returns it as it is now. If the move fails the
    /// meeting stays in staging, where it is still listed and transcribed, and
    /// the next launch tries again.
    @discardableResult
    static func publish(_ m: Meeting) -> Meeting {
        do {
            return try moveIntoMeetings(m)
        } catch {
            NSLog("Ata: could not move \(m.id) into the meetings folder, kept for the next launch: \(error)")
            return m
        }
    }

    /// `publish`, for a caller that tells you when the move failed. The id in
    /// the result is the folder's name in the meetings folder, which changes
    /// only if the name was taken there. Nothing is moved, and `m` comes back
    /// as it is, when it isn't in staging.
    static func moveIntoMeetings(_ m: Meeting) throws -> Meeting {
        let staged = Device.stagingDir.appendingPathComponent(m.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: staged.path) else { return m }
        let moved = try moveFolder(staged, into: Paths.meetingsDir)
        var m = m
        m.id = moved.lastPathComponent
        return m
    }

    /// In a staged folder from `Meeting.newImport` until the import is whole.
    /// Hidden, so it is never mistaken for a meeting's file.
    static let importMarker = ".importing"

    /// An import is decoded: saves its meeting.json, drops the marker and moves
    /// it into the meetings folder (or, if that fails, leaves it in staging for
    /// the next launch, like a recording). Throws, with the marker still in place,
    /// if meeting.json could not be written or the marker could not be removed:
    /// the caller then keeps its source, and the next launch clears the folder.
    static func finishImport(_ m: Meeting) throws -> Meeting {
        let fm = FileManager.default
        save(m)
        guard fm.fileExists(atPath: m.metaURL.path) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: m.metaURL.path])
        }
        let marker = m.dir.appendingPathComponent(importMarker)
        if fm.fileExists(atPath: marker.path) { try fm.removeItem(at: marker) }
        return publish(m)
    }

    /// After a crash: finishes what a recording left in staging (its WAV
    /// headers, its status), then moves it into the meetings folder. An import
    /// cut off before it was whole is removed instead: what it was decoding is
    /// still where it came from (the Watch's or the share sheet's inbox, which
    /// import it again, or the file you picked), so nothing is lost, and a
    /// half-decoded copy would only be a truncated duplicate.
    static func recoverStaged() {
        let fm = FileManager.default
        for id in stagedIDs() {
            let dir = Device.stagingDir.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: dir.appendingPathComponent(importMarker).path) {
                NSLog("Ata: removing an import that did not finish, \(id); its source is untouched")
                try? fm.removeItem(at: dir)
                continue
            }
            var m: Meeting
            if let saved = load(id) {
                m = saved
            } else {
                // Ata stopped between making the folder and writing meeting.json.
                let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
                if contents.isEmpty {
                    try? fm.removeItem(at: dir)
                    continue
                }
                let made = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
                m = Meeting(id: id, startedAt: made, endedAt: nil, duration: nil, app: nil,
                            status: .recording, error: nil)
                m.origin = Device.current
            }
            // Whatever its meeting.json says, a folder in this device's staging is this device's.
            if let fixed = m.recovered(by: m.origin ?? Device.current) {
                m = fixed
                save(m)
            }
            // Never move a folder something may still be writing.
            guard m.status != .recording else { continue }
            publish(m)
        }
    }

    /// Moves `source` into `parent` and returns where it ended up: a rename
    /// when it can be, otherwise a copy that is checked before the original is
    /// removed. Nothing is deleted that isn't proven to exist in the other
    /// place, so a failure at any step leaves `source` whole.
    static func moveFolder(_ source: URL, into parent: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        try CloudLibrary.createFolder(parent)
        let name = source.lastPathComponent
        var target = parent.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            // An earlier move copied everything but didn't get to remove the original.
            if covers(target, source) {
                try fm.removeItem(at: source)
                return target
            }
            target = unusedFolder(name, in: parent)
        }
        do {
            // Coordinated, so iCloud takes the new folder in as one change.
            try Coordinated.move(source, to: target)
            return target
        } catch {
            if !fm.fileExists(atPath: source.path), fm.fileExists(atPath: target.path) { return target }
            if fm.fileExists(atPath: target.path) {
                if covers(target, source) {
                    try? fm.removeItem(at: source)
                    return target
                }
                // Half a copy from the failed move: leave it, and copy in full beside it.
                target = unusedFolder(name, in: parent)
            }
        }
        // Hidden, so a copy that isn't finished is never listed.
        let partial = parent.appendingPathComponent(".\(target.lastPathComponent).partial", isDirectory: true)
        try? fm.removeItem(at: partial) // an earlier attempt's copy; the original is still in staging
        do {
            try fm.copyItem(at: source, to: partial)
            guard covers(partial, source) else { throw CocoaError(.fileWriteUnknown) }
            try Coordinated.move(partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        try? fm.removeItem(at: source)
        return target
    }

    /// Every file under `original` is also in `copy`, at the same place and with the same size.
    static func covers(_ copy: URL, _ original: URL) -> Bool {
        let fm = FileManager.default
        guard let paths = fm.subpaths(atPath: original.path) else { return false }
        for relative in paths {
            let file = original.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let other = copy.appendingPathComponent(relative)
            guard fm.fileExists(atPath: other.path), Paths.fileSize(other) == Paths.fileSize(file) else {
                return false
            }
        }
        return true
    }

    private static func unusedFolder(_ name: String, in parent: URL) -> URL {
        var n = 2
        var url = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
        }
        return url
    }

    /// Moves the meeting's folder to the Trash. False when it is still there.
    @discardableResult
    static func trash(_ m: Meeting) -> Bool {
        do {
            try Coordinated.trash(m.dir)
        } catch {
            NSLog("Ata: could not move \(m.id) to the Trash: \(error.localizedDescription)")
        }
        return !FileManager.default.fileExists(atPath: m.dir.path)
    }
}
