import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Your notes and the AI summary of one meeting, as files in its folder.
enum MeetingNotes {
    static func load(for m: Meeting) -> String {
        (try? String(contentsOf: m.notesURL, encoding: .utf8)) ?? ""
    }

    /// Saves your notes as notes.md. Clearing them removes the file, so an
    /// empty notes.md never lingers in the folder.
    static func save(_ text: String, for m: Meeting) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: m.notesURL)
        } else {
            try text.write(to: m.notesURL, atomically: true, encoding: .utf8)
        }
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
        let raw = "\(m.title) \(f.string(from: m.startedAt))"
        // App names come from the system; keep them from making a path.
        return raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
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
    /// transcript.md, for meetings transcribed before transcript.json existed.
    @Published private(set) var markdown: String?
    @Published private(set) var hasStoredTranscript = false
    @Published private(set) var speakers: [Speaker] = []
    @Published private(set) var participants: [String] = []

    @Published var notes = ""
    @Published private(set) var writingNotes = false
    @Published private(set) var exporting = false
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
        reload()
        if let meeting {
            notes = MeetingNotes.load(for: meeting)
            savedNotes = notes
        }
    }

    func reload() {
        guard let m = Library.load(id) else {
            meeting = nil
            return
        }
        meeting = m
        let myName = Pref.myNameOrDefault
        let names = Speakers.names(for: m, myName: myName)

        if let stored = StoredTranscript.load(from: m.storedTranscriptURL) {
            hasStoredTranscript = true
            lines = Transcriber.blocks(stored).enumerated().map { i, b in
                Line(id: i, start: b.start, end: b.end, speaker: b.speaker, name: names(b.speaker), text: b.text)
            }
            coarse = stored.coarse
            summary = stored.summary
            markdown = nil
        } else {
            hasStoredTranscript = false
            lines = []
            coarse = false
            summary = nil
            markdown = m.existingTranscriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }

        let map = MeetingVoices.load(for: m)
        let voices = PeopleModel.shared.voices
        speakers = (map?.speakers ?? [])
            .filter { $0.label != Speakers.me }
            .sorted { Self.number($0.label) < Self.number($1.label) }
            .map { s in
                let voice = s.voiceID.flatMap { id in voices.first { $0.id == id } }
                let longest = map?.turns.filter { $0.label == s.label }.max { ($0.end - $0.start) < ($1.end - $1.start) }
                return Speaker(label: s.label, voice: voice, name: voice?.displayName ?? names(s.label),
                               seconds: s.seconds, sampleStart: longest?.start)
            }

        var people = [myName]
        for line in lines where !people.contains(line.name) { people.append(line.name) }
        participants = people

        guard !Snapshots.rendering else { return }
        if !player.loaded, m.hasAudio || m.hasMergedAudio {
            player.load(m)
        }
        // Meetings from before Ata saved an MP3 get one the first time they're opened.
        AppStore.shared.saveMergedAudio(of: m)
        prepareSharing(m)
    }

    /// Makes the share copies: the transcript again whenever it changes (a
    /// voice was named, notes were written), the audio once.
    private func prepareSharing(_ m: Meeting) {
        let stamp = m.existingTranscriptURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        if stamp != sharedTranscriptStamp {
            sharedTranscript = try? MeetingSharing.transcript(of: m, in: shareDir)
            sharedTranscriptStamp = stamp
        }

        guard sharedAudio == nil, !preparingAudio, m.hasAudio || m.hasMergedAudio else { return }
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

    func saveNotes() {
        pendingSave?.cancel()
        guard let meeting, notes != savedNotes else { return }
        do {
            try MeetingNotes.save(notes, for: meeting)
            savedNotes = notes
        } catch {
            message = L("Could not save your notes: %@", error.localizedDescription)
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
            message = onThisMac
                ? L("Could not write notes on this Mac. Try again, or choose OpenAI in Settings.")
                : L("Could not write notes. Check your OpenAI key in Settings and try again.")
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

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Saves the meeting as one MP3 wherever you choose.
    func exportMP3() {
        guard let meeting, !exporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = MeetingSharing.name(for: meeting) + ".mp3"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        exporting = true
        message = nil
        Task {
            let m = meeting
            do {
                try await Task.detached(priority: .userInitiated) {
                    try MeetingSharing.audio(of: m, to: destination, link: false)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                message = L("Could not save the MP3: %@", error.localizedDescription)
            }
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

    func load(_ m: Meeting) {
        guard !loaded, !loading else { return }
        loading = true
        Task {
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
        guard loaded else { playWhenLoaded = true; return }
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
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4),
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
