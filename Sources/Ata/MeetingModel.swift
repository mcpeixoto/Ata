import AVFoundation
import Combine
import Foundation
import UniformTypeIdentifiers

/// Where playback is in the transcript: the line being heard and its word.
struct PlaybackCursor: Equatable {
    var line: Int
    /// Nil in the pause after a line, before the next one starts.
    var word: Int?

    /// The last line started by `ms`, and its last word started by then. Times
    /// lead by `WordTiming.leadMs`, because Whisper's word times run late.
    static func at(_ ms: Int, in lines: [MeetingModel.Line]) -> PlaybackCursor? {
        let t = ms + WordTiming.leadMs
        guard let line = lastIndex(in: lines.map(\.start), atOrBefore: t) else { return nil }
        let l = lines[line]
        guard t <= l.end + 500 else { return PlaybackCursor(line: line, word: nil) }
        return PlaybackCursor(line: line, word: lastIndex(in: l.words.map(\.start), atOrBefore: t))
    }

    /// Binary search over ascending starts.
    static func lastIndex(in starts: [Int], atOrBefore t: Int) -> Int? {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}

/// A word in the transcript is a link to its moment in the audio.
enum SeekLink {
    static func url(ms: Int) -> URL { URL(string: "ata-seek://t/\(max(0, ms))")! }

    static func ms(_ url: URL) -> Int? {
        guard url.scheme == "ata-seek", url.host == "t" else { return nil }
        return Int(url.lastPathComponent)
    }
}

/// Your notes and the AI summary of one meeting, as files in its folder.
enum MeetingNotes {
    static func load(for m: Meeting) -> String {
        (try? String(contentsOf: m.notesURL, encoding: .utf8)) ?? ""
    }

    /// Saves your notes as notes.md. Clearing them removes the file, so an
    /// empty notes.md never lingers in the folder.
    static func save(_ text: String, for m: Meeting) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? Coordinated.remove(m.notesURL)
        } else {
            try Coordinated.write(text, to: m.notesURL)
        }
    }

    /// Keeps `text` beside notes.md, as "notes (other device).md" or the next free
    /// name, so a version of your notes that isn't kept as notes.md is never lost.
    static func keepAside(_ text: String, for m: Meeting) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let name = Conflicts.unusedAsideName(for: m.notesURL.lastPathComponent, in: m.dir)
        try Coordinated.write(text, to: m.dir.appendingPathComponent(name))
    }

    /// Adds a summary written after the meeting was transcribed: into
    /// transcript.json, into transcript.md, and its cost into the latest
    /// transcription so Insights stays right. Returns the updated meeting.
    static func addSummary(_ text: String, costUSD: Double, to m: Meeting, myName: String) throws -> Meeting {
        guard var stored = StoredTranscript.load(from: m.storedTranscriptURL) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: m.storedTranscriptURL.path])
        }
        stored.summary = text
        try stored.save(to: m.storedTranscriptURL)
        try Transcriber.rerender(m, myName: myName)

        var m = m
        if var history = m.transcriptions, !history.isEmpty {
            history[history.count - 1].costUSD += costUSD
            m.transcriptions = history
        }
        Library.save(m)
        return m
    }

    /// The summary for reading in the app: SwiftUI's `Text` draws inline
    /// Markdown only, so list dashes become bullets by hand.
    static func display(_ summary: String) -> AttributedString {
        let text = summary
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.hasPrefix("- ") ? "•  " + line.dropFirst(2) : String(line)
            }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: text,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// What the meeting window does with your notes when notes.md may have changed
/// under it: on the other device, with the library in iCloud.
enum NotesRefresh {
    enum Action: Equatable {
        /// notes.md is as last saved, or already holds what's in the window.
        case keep
        /// Nothing typed since the last save: the window shows notes.md as it is now.
        case load
        /// Typed here and changed there: what's typed is saved as notes.md, and the
        /// file's version is kept beside it.
        case keepBoth
    }

    /// `buffer` is what the window holds, `saved` what it last saved or loaded, and
    /// `disk` notes.md now ("" when there is none).
    static func decide(buffer: String, saved: String, disk: String) -> Action {
        if disk == saved || disk == buffer { return .keep }
        return buffer == saved ? .load : .keepBoth
    }
}

/// Files to hand to the share sheet, AirDrop or a drag, named after the
/// meeting so whoever gets them sees "Zoom 2026-10-22 14.02.mp3", not "meeting.mp3".
enum MeetingSharing {
    /// A folder of its own under the temporary directory, emptied at launch:
    /// a share sheet may still be reading a file after its window closed.
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Ata Share", isDirectory: true)

    static func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    static func name(for m: Meeting) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        // Through the same sanitiser the folder name uses. This hand-rolled its
        // own two replacements, which was enough while a title was an app name
        // from the system; a calendar event's title is the user's own text.
        let raw = "\(m.title) \(f.string(from: m.startedAt))"
        return FolderNames.safe(raw) ?? f.string(from: m.startedAt)
    }

    /// The meeting's audio as one MP3 at `destination`: meeting.mp3 when there
    /// is one, otherwise the tracks mixed straight into `destination` — which
    /// is how a meeting from before 2.4, or with the MP3 setting off, is shared.
    /// `link` hard-links instead of copying when it can, for throwaway share copies.
    static func audio(of m: Meeting, to destination: URL, link: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if m.hasMergedAudio {
            if link, (try? fm.linkItem(at: m.mergedAudioURL, to: destination)) != nil { return }
            try fm.copyItem(at: m.mergedAudioURL, to: destination)
        } else {
            try MergedAudio.write(tracks: [m.micAudioURL, m.systemAudioURL].compactMap { $0 }, to: destination)
        }
    }

    /// transcript.md under the meeting's name, or nil before there is one.
    static func transcript(of m: Meeting, in dir: URL) throws -> URL? {
        guard let source = m.existingTranscriptURL else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(name(for: m) + ".md")
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.copyItem(at: source, to: out)
        return out
    }
}

/// Everything the meeting window shows, loaded from the meeting's folder and
/// loaded again whenever the history or a voice's name changes.
@MainActor
final class MeetingModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: Int
        let start: Int // ms
        let end: Int   // ms
        let speaker: String
        let name: String
        let text: String
        /// As transcribed, or estimated for older transcripts; see `WordTiming`.
        let words: [StoredTranscript.Word]
    }

    /// A moment marked while recording, with the line being said then.
    struct Moment: Identifiable, Equatable {
        let bookmark: Bookmark
        let line: Line?
        var id: UUID { bookmark.id }

        /// Where "play" starts: the start of the line it points at, so the
        /// words that prompted the mark are heard whole.
        var playFromMs: Int { min(line?.start ?? bookmark.ms, bookmark.ms) }
    }

    /// A voice heard in this meeting, other than yours.
    struct Speaker: Identifiable, Equatable {
        let label: String
        let voice: Voice?
        let name: String
        let seconds: Double
        /// Where this speaker's longest turn starts, for "play".
        let sampleStart: Int?
        var id: String { label }
    }

    let id: String
    let player = MeetingPlayer()

    @Published private(set) var meeting: Meeting?
    @Published private(set) var lines: [Line] = []
    @Published private(set) var coarse = false
    @Published private(set) var summary: String?
    /// A side of the recording held no sound; see `TrackHealth`.
    @Published private(set) var healthWarning: String?
    /// transcript.md, for meetings transcribed before transcript.json existed.
    @Published private(set) var markdown: String?
    @Published private(set) var hasStoredTranscript = false
    @Published private(set) var speakers: [Speaker] = []
    @Published private(set) var participants: [String] = []
    /// What was marked while recording, in time order.
    @Published private(set) var moments: [Moment] = []

    @Published var notes = ""
    /// notes.md is still in iCloud: shown as downloading, and not editable until it arrives.
    @Published private(set) var notesDownloading = false
    /// transcript.json or transcript.md is still in iCloud.
    @Published private(set) var transcriptDownloading = false
    @Published private(set) var writingNotes = false
    @Published private(set) var exporting = false
    /// The save panel is up: a second click must not open another.
    private var choosingDestination = false
    @Published var message: String?

    /// Ready-to-share copies; see `MeetingSharing`.
    @Published private(set) var sharedAudio: URL?
    @Published private(set) var sharedTranscript: URL?
    @Published private(set) var preparingAudio = false
    private let shareDir = MeetingSharing.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var sharedTranscriptStamp: Date?

    private var savedNotes = ""
    private var pendingSave: DispatchWorkItem?

    init(id: String) {
        self.id = id
        PeopleModel.shared.reload()
        // Reads your notes too; see `refreshNotes`.
        reload()
        // The transcript follows the audio, but only redraws when the word changes.
        player.$time
            .sink { [weak self] t in MainActor.assumeIsolated { self?.follow(t) } }
            .store(in: &watchers)
        player.$isPlaying
            .sink { [weak self] p in MainActor.assumeIsolated { self?.playing = p } }
            .store(in: &watchers)
        #if os(iOS)
        // The iPhone's screenshot run opens its meeting mid-playback; the Mac's
        // renderer sets the position itself.
        Snapshots.position(player, meeting: id)
        #endif
    }

    /// The line and word being heard, published only when it changes.
    @Published private(set) var cursor: PlaybackCursor?
    @Published private(set) var playing = false
    /// You in one lane, the others in the other; nil until it has been computed.
    @Published private(set) var waveform: Waveform?
    private var watchers: Set<AnyCancellable> = []
    private var computingWaveform = false

    private func follow(_ seconds: Double) {
        let next = seconds > 0 || playing ? PlaybackCursor.at(Int(seconds * 1000), in: lines) : nil
        if next != cursor { cursor = next }
    }

    /// From a word or a timestamp in the transcript.
    func play(fromMs ms: Int) {
        player.seek(to: Double(ms) / 1000)
        player.play()
    }

    func reload() {
        guard let m = Library.load(id) else {
            meeting = nil
            return
        }
        meeting = m
        refreshNotes(m)
        let myName = Pref.myNameOrDefault
        let names = Speakers.names(for: m, myName: myName)

        // Files still in iCloud are asked for, not waited on: this is the main thread.
        // The watcher reloads once they have arrived.
        let storedHere = CloudFiles.readable(m.storedTranscriptURL) != nil
        if storedHere, let stored = StoredTranscript.load(from: m.storedTranscriptURL) {
            hasStoredTranscript = true
            lines = Transcriber.blocks(stored.excluding(Speakers.leftOut(for: m))).enumerated().map { i, b in
                Line(id: i, start: b.start, end: b.end, speaker: b.speaker, name: names(b.speaker), text: b.text,
                     words: WordTiming.words(of: b))
            }
            coarse = stored.coarse
            summary = stored.summary
            healthWarning = stored.health.flatMap(TrackHealth.init(rawValue:))?.warning
            markdown = nil
            transcriptDownloading = false
        } else {
            hasStoredTranscript = false
            lines = []
            coarse = false
            summary = nil
            healthWarning = nil
            let markdownHere = !m.transcriptFiles.contains { CloudFiles.readable($0) == nil }
            let file = storedHere && markdownHere ? m.existingTranscriptURL : nil
            markdown = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            transcriptDownloading = !storedHere || !markdownHere
        }
        if m.systemAudioCorrupt == true {
            healthWarning = TrackHealth.systemAudioCorrupt.warning
        }

        let map = MeetingVoices.load(for: m)
        let voices = PeopleModel.shared.voices
        // Every label the diarizer found, not only the ones that could be
        // fingerprinted. A speaker Ata heard for a few seconds has no voice to
        // match, but they did speak, and a row that says so beats a People tab
        // insisting nobody else did while the transcript quotes them.
        let known = Dictionary(uniqueKeysWithValues: (map?.speakers ?? []).map { ($0.label, $0) })
        let labels = (map?.turns ?? []).map(\.label) + (map?.speakers ?? []).map(\.label)
        speakers = Array(Set(labels))
            .sorted { Self.number($0) < Self.number($1) }
            .map { label in
                let found = known[label]
                let voice = found?.voiceID.flatMap { id in voices.first { $0.id == id } }
                let turns = (map?.turns ?? []).filter { $0.label == label }
                let longest = turns.max { ($0.end - $0.start) < ($1.end - $1.start) }
                let seconds = found?.seconds
                    ?? turns.reduce(0.0) { $0 + Double($1.end - $1.start) / 1000 }
                return Speaker(label: label, voice: voice, name: voice?.displayName ?? names(label),
                               seconds: seconds, sampleStart: longest?.start)
            }

        var people = [myName]
        for line in lines where !people.contains(line.name) { people.append(line.name) }
        participants = people
        moments = Self.moments(m.bookmarks ?? [], in: lines)

        let waveformHere = CloudFiles.readable(m.waveformURL) != nil
        if waveform == nil, waveformHere { waveform = Waveform.read(from: m.waveformURL) }
        guard !Snapshots.rendering else { return }
        if !player.loaded, m.hasAudio || m.hasMergedAudio {
            player.load(m)
        }
        // Meetings transcribed before Ata 2.5 get their waveform the first time they're opened.
        // Not from audio still in iCloud: opening a meeting doesn't download its recording.
        // Nor while the waveform itself is on its way.
        if waveform == nil, waveformHere, m.hasAudio, !computingWaveform,
           CloudFiles.areLocal([m.micAudioURL, m.systemAudioURL].compactMap { $0 }) {
            computingWaveform = true
            let mic = m.micAudioURL, system = m.systemAudioURL, file = m.waveformURL
            Task {
                let computed = await Task.detached(priority: .utility) { () -> Waveform? in
                    guard let w = try? Waveform.compute(mic: mic, system: system) else { return nil }
                    try? w.write(to: file)
                    return w
                }.value
                if let computed { waveform = computed }
                computingWaveform = false
            }
        }
        // Meetings from before Ata saved an MP3 get one the first time they're opened.
        AppStore.shared.saveMergedAudio(of: m)
        prepareSharing(m)
    }

    /// Makes the share copies: the transcript again whenever it changes (a
    /// voice was named, notes were written), the audio once.
    private func prepareSharing(_ m: Meeting) {
        // Copying a transcript still in iCloud would wait for it here, on the main thread.
        if let transcript = m.existingTranscriptURL, CloudFiles.readable(transcript) == nil { return }
        let stamp = m.existingTranscriptURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        if stamp != sharedTranscriptStamp {
            sharedTranscript = try? MeetingSharing.transcript(of: m, in: shareDir)
            sharedTranscriptStamp = stamp
        }

        guard sharedAudio == nil, !preparingAudio, m.hasAudio || m.hasMergedAudio else { return }
        // Audio still in iCloud is shared once it has been played, and so downloaded.
        let audio = m.hasMergedAudio ? [m.mergedAudioURL] : [m.micAudioURL, m.systemAudioURL].compactMap { $0 }
        guard CloudFiles.areLocal(audio) else { return }
        preparingAudio = true
        let destination = shareDir.appendingPathComponent(MeetingSharing.name(for: m) + ".mp3")
        Task {
            // If meeting.mp3 is being written, share that rather than mixing twice.
            await AppStore.shared.saveMergedAudio(of: m)?.value
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MeetingSharing.audio(of: m, to: destination, link: true)
                }.value
                sharedAudio = destination
            } catch {
                message = L("Could not prepare the audio for sharing: %@", error.localizedDescription)
            }
            preparingAudio = false
        }
    }

    /// Your notes and the summary as one text, for copying and sharing.
    var notesText: String {
        var parts: [String] = []
        if let summary { parts.append(summary) }
        let mine = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { parts.append(mine) }
        return parts.joined(separator: "\n\n")
    }

    nonisolated static func moments(_ bookmarks: [Bookmark], in lines: [Line]) -> [Moment] {
        let starts = lines.map(\.start), ends = lines.map(\.end)
        return bookmarks.sorted { $0.ms < $1.ms }.map { b in
            Moment(bookmark: b, line: Bookmark.nearest(to: b.ms, starts: starts, ends: ends).map { lines[$0] })
        }
    }

    /// Plays from a marked moment.
    func play(_ moment: Moment) {
        play(fromMs: moment.playFromMs)
    }

    /// "S12" → 12, so speakers list in the order they first spoke.
    private static func number(_ label: String) -> Int {
        Int(label.drop { !$0.isNumber }) ?? 0
    }

    /// The window is closing: stop the audio and save what was typed.
    func close() {
        saveNotes()
        player.close()
    }

    // MARK: Notes

    /// Saves your notes shortly after you stop typing.
    func notesChanged() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNotes() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes what's typed as notes.md. If notes.md changed meanwhile (on the other
    /// device), its version is kept beside it first; if it's still in iCloud, what's
    /// typed goes beside it instead, and the window shows notes.md once it arrives.
    func saveNotes() {
        pendingSave?.cancel()
        guard let meeting, notes != savedNotes else { return }
        do {
            if CloudFiles.readable(meeting.notesURL) == nil {
                try MeetingNotes.keepAside(notes, for: meeting)
                savedNotes = notes
                notesDownloading = true
                return
            }
            let disk = MeetingNotes.load(for: meeting)
            if disk != savedNotes, disk != notes { try MeetingNotes.keepAside(disk, for: meeting) }
            try MeetingNotes.save(notes, for: meeting)
            savedNotes = notes
        } catch {
            message = L("Could not save your notes: %@", error.localizedDescription)
        }
    }

    /// Your notes as notes.md has them now, which the other device may have changed;
    /// see `NotesRefresh`. Notes still in iCloud are shown as downloading and can't be
    /// edited, so nothing typed here is ever saved over a version not seen yet.
    private func refreshNotes(_ m: Meeting) {
        guard CloudFiles.readable(m.notesURL) != nil else {
            notesDownloading = true
            return
        }
        notesDownloading = false
        let disk = MeetingNotes.load(for: m)
        switch NotesRefresh.decide(buffer: notes, saved: savedNotes, disk: disk) {
        case .keep:
            if disk == notes { savedNotes = disk }
        case .load:
            // Saved first: the editor sees the new text as already saved.
            savedNotes = disk
            notes = disk
        case .keepBoth:
            saveNotes()
        }
    }

    /// Asks for a summary of a meeting that was transcribed without one.
    func writeNotes() async {
        guard let meeting, !writingNotes,
              let stored = StoredTranscript.load(from: meeting.storedTranscriptURL) else { return }
        writingNotes = true
        message = nil
        defer { writingNotes = false }

        var options = TranscribeOptions.current()
        let onThisMac = Summarizer.engine(preference: options.summaryEngine, appleAvailable: AppleModel.isAvailable,
                                          hasOpenAIKey: Keychain.has(Keychain.openAIKey)) == .apple
        // The button said nothing leaves this Mac, so "auto" must not fall back to OpenAI here.
        if onThisMac { options.summaryEngine = SummaryEngine.apple.rawValue }
        let draft = Transcriber.render(stored, meeting: meeting,
                                       names: Speakers.names(for: meeting, myName: options.myName))
        guard let result = await Summarizer.summarize(markdown: draft, options: options) else {
            #if os(iOS)
            message = L("Could not write notes on this iPhone. Try again.")
            #else
            message = onThisMac
                ? L("Could not write notes on this Mac. Try again, or choose OpenAI in Settings.")
                : L("Could not write notes. Check your OpenAI key in Settings and try again.")
            #endif
            return
        }
        do {
            _ = try MeetingNotes.addSummary(result.text, costUSD: result.costUSD, to: meeting, myName: options.myName)
        } catch {
            message = error.localizedDescription
        }
        AppStore.shared.reload()
        reload()
    }

    // MARK: Voices

    func rename(_ speaker: Speaker, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let voice = speaker.voice, !trimmed.isEmpty else { return }
        PeopleModel.shared.rename(voice, to: trimmed)
        reload()
    }

    func merge(_ speaker: Speaker, into other: Voice) {
        guard let voice = speaker.voice else { return }
        PeopleModel.shared.merge(voice, into: other)
        reload()
    }

    func dismiss(_ speaker: Speaker, _ on: Bool) {
        guard let voice = speaker.voice else { return }
        PeopleModel.shared.dismiss(voice, on)
        reload()
    }

    /// "This speaker is me", or no longer me: the one way to tell Ata which voice
    /// in the room is yours, and the only one on an iPhone.
    func setMe(_ speaker: Speaker, _ on: Bool) {
        guard let voice = speaker.voice else { return }
        PeopleModel.shared.setMe(voice, on)
        reload()
    }

    /// Leaves this voice out of every transcript, this one included, or puts it back.
    func exclude(_ speaker: Speaker, _ on: Bool) {
        guard let voice = speaker.voice else { return }
        PeopleModel.shared.setExcluded(voice, on)
        reload()
    }

    func play(_ speaker: Speaker) {
        guard let start = speaker.sampleStart else { return }
        player.seek(to: Double(start) / 1000)
        player.play()
    }

    // MARK: Sharing

    func copyTranscript() {
        guard let url = meeting?.existingTranscriptURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        copy(text)
    }

    func copyNotes() {
        guard !notesText.isEmpty else { return }
        copy(notesText)
    }

    /// A follow-up email drafted from the summary, on the clipboard: subject,
    /// the overview as the body, the action items as next steps.
    func copyFollowUp() {
        guard let meeting, let summary, !summary.isEmpty else { return }
        copy(FollowUp.draft(summary: summary, meetingTitle: meeting.title, myName: Pref.myNameOrDefault))
        message = L("Follow-up draft copied — paste it into your email.")
    }

    private func copy(_ text: String) {
        Platform.actions.copy(text)
    }

    /// Saves the meeting as one MP3 wherever you choose.
    func exportMP3() {
        guard let meeting, !exporting, !choosingDestination else { return }
        choosingDestination = true
        Task {
            let m = meeting
            do {
                _ = try await Platform.actions.saveFile(named: MeetingSharing.name(for: m) + ".mp3",
                                                        type: .mp3) { [weak self] destination in
                    self?.exporting = true
                    self?.message = nil
                    try await Task.detached(priority: .userInitiated) {
                        try MeetingSharing.audio(of: m, to: destination, link: false)
                    }.value
                }
            } catch {
                message = L("Could not save the MP3: %@", error.localizedDescription)
            }
            choosingDestination = false
            exporting = false
        }
    }
}

/// Plays a meeting: meeting.mp3 when there is one, otherwise both tracks
/// mixed on the fly, so listening never waits for a file to be written.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var loaded = false
    @Published var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }

    static let rates: [Float] = [1, 1.25, 1.5, 2]

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loading = false
    private var playWhenLoaded = false
    /// A meeting whose audio is still in iCloud: loaded when it is played.
    private var waiting: Meeting?

    func load(_ m: Meeting) {
        guard !loaded, !loading else { return }
        let files = m.hasMergedAudio ? [m.mergedAudioURL] : [m.micAudioURL, m.systemAudioURL].compactMap { $0 }
        // Audio still in iCloud is downloaded when it's played, not when the meeting is opened.
        guard playWhenLoaded || CloudFiles.areLocal(files) else {
            waiting = m
            return
        }
        waiting = nil
        loading = true
        Task {
            if !CloudFiles.areLocal(files) { _ = await CloudFiles.download(files) }
            let asset: AVAsset?
            if m.hasMergedAudio {
                asset = AVURLAsset(url: m.mergedAudioURL)
            } else {
                asset = await Self.mix([m.micAudioURL, m.systemAudioURL].compactMap { $0 })
            }
            loading = false
            guard let asset else { return }
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            duration = seconds.isFinite ? seconds : 0
            observe(item)
            loaded = true
            if playWhenLoaded { play() }
        }
    }

    func play() {
        guard loaded else {
            playWhenLoaded = true
            if let waiting { load(waiting) }
            return
        }
        playWhenLoaded = false
        if duration > 0, time >= duration - 0.1 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        playWhenLoaded = false
        player.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    /// For the snapshot renderer only: a moment in the meeting, without audio.
    func applySnapshotPosition(_ seconds: Double, duration: Double) {
        self.duration = duration
        time = seconds
    }

    func close() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        loaded = false
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? duration : seconds
        let t = max(0, min(seconds, upper))
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: Double) { seek(to: time + seconds) }

    private func observe(_ item: AVPlayerItem) {
        // 20 Hz, so the highlighted word keeps up with the voice.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20),
                                                      queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, t.seconds.isFinite else { return }
                self.time = t.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
    }

    /// Both tracks laid over each other, played together.
    private static func mix(_ tracks: [URL]) async -> AVAsset? {
        let composition = AVMutableComposition()
        for url in tracks {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await source.load(.timeRange),
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? track.insertTimeRange(range, of: source, at: .zero)
        }
        return composition.tracks.isEmpty ? nil : composition
    }
}
