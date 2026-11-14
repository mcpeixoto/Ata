import AVFoundation
import SwiftUI

/// Finds who spoke when in a track, and a voice fingerprint for each speaker.
/// The implementation is chosen in Diarization.swift.
protocol Diarizer {
    /// Speaker turns and one embedding per speaker label.
    func diarize(_ wav: URL) async throws -> (turns: [SpeakerTurn], embeddings: [String: [Float]])
    /// The main speaker of a track, with the share of the track's speech that
    /// speaker holds — 1.0 when the track really is one person, and much less
    /// when it is a room. `minimumSecondsToLearn` is the speech a speaker must
    /// have for a fingerprint worth keeping; a recording you made of yourself on
    /// purpose needs no such floor, so it passes 0.
    func mainSpeaker(_ wav: URL, minimumSecondsToLearn: Double) async throws
        -> (embedding: [Float], share: Double)?
}

extension Diarizer {
    /// One embedding for a track you know is a single speaker: a clip you
    /// recorded of yourself, where whatever is there is your voice.
    func embed(_ wav: URL) async throws -> [Float]? {
        try await mainSpeaker(wav, minimumSecondsToLearn: 0)?.embedding
    }
}

/// The voice library as the UI sees it: loaded once, saved on every change,
/// and every affected transcript re-rendered when a name changes.
@MainActor
final class PeopleModel: ObservableObject {
    static let shared = PeopleModel()

    @Published private(set) var voices: [Voice] = []
    @Published private(set) var playing: UUID?

    /// When a change reaches the transcripts it affects. A meeting's own window
    /// reads its transcript straight after, so that is the default; the People tab
    /// has a list to keep moving, and a voice can be in a hundred meetings.
    /// `.focused` redraws that one meeting before returning and the rest later,
    /// so naming someone in one window does not re-render every meeting on the main thread.
    enum Redraw { case now, background, focused(String) }

    /// Bumps when a redraw has reached the transcripts, including one that ran
    /// in the background. Open meeting windows reload on it: `$voices` fires
    /// before the new value is visible, and a merge's repoint finishes later.
    @Published private(set) var redrawsDone = 0

    private var library = VoiceLibrary()
    private var player: AVAudioPlayer?

    var enabled: Bool { Pref.d.bool(forKey: Pref.recogniseVoices) }

    var worthAsking: [Voice] { library.worthAsking }
    var named: [Voice] { PeopleList.named(voices) }
    var me: Voice? { voices.first(where: \.isMe) }

    /// The calendar event of each meeting that has one, for the suggestions
    /// below. Built from the meeting.json files `Library.loadAll` reads anyway.
    /// A meeting still on its way down from iCloud comes back as a placeholder
    /// with no event — read, never waited for.
    @Published private var eventsByMeeting: [String: MeetingEvent] = [:]
    private var eventsLoad: Task<Void, Never>?
    /// Transcripts being drawn in the background, one change after another.
    private var redraws: Task<Void, Never>?

    func reload() {
        library = VoiceLibrary()
        // Every open meeting reparses its transcript when this publishes, so an
        // unchanged library must not. Same family as the 3.5.2 freeze.
        if voices != library.voices { voices = library.voices }
        // Every meeting's file: never on the main thread, and only a hint until it lands.
        eventsLoad?.cancel()
        eventsLoad = Task.detached(priority: .utility) { [weak self] in
            let events = Dictionary(Library.loadAll().compactMap { m in m.event.map { (m.id, $0) } },
                                    uniquingKeysWith: { first, _ in first })
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.eventsByMeeting = events }
        }
    }

    /// The tab's list, for a search or none.
    func sections(query: String) -> [PeopleList.Section] {
        PeopleList.sections(voices: voices, query: query, heardOnceShown: Self.heardOnceShown)
    }

    /// Who "Same person as" offers for this voice.
    func mergeTargets(for voice: Voice) -> [Voice] {
        PeopleList.mergeTargets(for: voice, voices: voices, likely: sameAs(voice))
    }

    func mergeChoices(for voice: Voice, query: String) -> PeopleList.MergeChoices {
        PeopleList.mergeChoices(for: voice, voices: voices, likely: sameAs(voice), query: query)
    }

    /// Returns once every change so far has reached its transcripts.
    func finishRedraws() async {
        await redraws?.value
    }

    /// Who the calendar says this voice might be, best first. Suggestions only:
    /// nothing here names anything until the user taps one.
    func suggestions(for voice: Voice) -> [VoiceSuggestions.Candidate] {
        VoiceSuggestions.candidates(for: voice, events: events(of: voice),
                                    otherVoices: voices.filter { $0.id != voice.id },
                                    myName: Pref.myNameOrDefault)
    }

    /// Voices the calendar says this one is probably the same person as.
    func sameAs(_ voice: Voice) -> [Voice] {
        VoiceSuggestions.sameAs(voice, events: events(of: voice), voices: voices)
    }

    private func events(of voice: Voice) -> [MeetingEvent] {
        voice.meetingIDs.compactMap { eventsByMeeting[$0] }
    }

    /// The user tapped a name the calendar offered. The old name, if there was
    /// one, is kept as an alias — so the next invitation still finds them.
    func accept(_ suggestion: VoiceSuggestions.Candidate, for voice: Voice, redraw: Redraw = .now) {
        let previous = voice.name
        library.rename(voice.id, to: suggestion.name)
        if let previous, !previous.isEmpty { library.addAlias(voice.id, previous) }
        if let email = suggestion.email { library.addAlias(voice.id, email) }
        persist()
        apply(redraw, meetings: voice.meetingIDs)
    }

    func addAlias(_ voice: Voice, _ alias: String) {
        library.addAlias(voice.id, alias)
        persist()
    }

    func removeAlias(_ voice: Voice, _ alias: String) {
        library.removeAlias(voice.id, alias)
        persist()
    }

    /// Called by the transcription queue with the speakers of a finished meeting.
    func assign(_ speakers: [MeetingSpeaker], meetingID: String) -> [MeetingSpeaker] {
        library = VoiceLibrary()
        let out = library.assign(speakers, meetingID: meetingID)
        persist()
        return out
    }

    /// A clip you recorded of yourself becomes the voice that is you: marked,
    /// named by `Pref.myName`, and linked to the voice already heard in meetings
    /// when it is the same person. Every transcript that voice appears in is
    /// drawn again.
    /// Awaits the sample copy rather than spawning it: the caller deletes the
    /// clip as soon as this returns, and a copy still reading it would find
    /// nothing, leaving the voice with no sample to play back.
    func enrolMe(embedding: [Float], clip: URL) async {
        library = VoiceLibrary()
        let voice = library.enrolMe(embedding: embedding)
        persist()
        if let sample = await VoiceSamples.keep(clip: clip, voice: voice.id) {
            setSample(voice.id, file: sample)
        }
        rerender(meetings: voice.meetingIDs)
    }

    /// Your voice as the library knows it now, read fresh: an in-person meeting
    /// looks for it among the people in the room.
    func myFingerprints() -> [[Float]] {
        reload()
        return library.myFingerprints
    }

    /// Voices only this meeting introduced go, with their samples; see `VoiceLibrary.save`.
    func removeMeeting(_ meetingID: String) {
        library = VoiceLibrary()
        library.removeMeeting(meetingID)
        persist()
    }

    func setSample(_ id: UUID, file: String) {
        library.setSample(id, file: file)
        persist()
    }

    func rename(_ voice: Voice, to name: String, redraw: Redraw = .now) {
        library.rename(voice.id, to: name)
        persist()
        apply(redraw, meetings: voice.meetingIDs)
    }

    func merge(_ source: Voice, into target: Voice, redraw: Redraw = .now) {
        library.merge(source.id, into: target.id)
        persist()
        // Meetings that pointed at the source now point at the target.
        apply(redraw, meetings: source.meetingIDs + target.meetingIDs,
              repoint: source.meetingIDs.map { Repoint(meetingID: $0, from: source.id, to: target.id) })
    }

    /// Stop asking for this voice's name.
    func dismiss(_ voice: Voice, _ on: Bool = true) {
        library.setDismissed(voice.id, on)
        persist()
    }

    /// "This voice is me", or no longer me: the next meeting in the room knows
    /// which of its speakers is you. Transcripts are redrawn because the voice
    /// leaves, or rejoins, the people listed in them.
    func setMe(_ voice: Voice, _ on: Bool, redraw: Redraw = .now) {
        library.setMe(voice.id, on)
        persist()
        apply(redraw, meetings: voice.meetingIDs)
    }

    /// Leave this voice out of every transcript, or put it back; transcripts are redrawn.
    func setExcluded(_ voice: Voice, _ on: Bool, redraw: Redraw = .now) {
        library.setExcluded(voice.id, on)
        persist()
        apply(redraw, meetings: voice.meetingIDs)
    }

    /// How many one-off voices the tab shows. A meeting or two is the point of
    /// the section; a year of them would bury "Who's this?" under strangers.
    static let heardOnceShown = 5

    /// Unnamed voices heard only once, so not yet worth asking about, most
    /// recent first. They are still listed: before this, one meeting's voices
    /// showed up nowhere in the tab, which read as "Ata didn't recognise anyone"
    /// — the more so on an iPhone, where a first recording is usually the only
    /// one there is.
    var heardOnce: [Voice] {
        Array(PeopleList.heardOnce(voices).prefix(Self.heardOnceShown))
    }

    /// Voices that are neither named nor asked about: dismissed, or left out.
    var hidden: [Voice] { PeopleList.hidden(voices) }

    /// The voice's file and sample go with it.
    func forget(_ voice: Voice, redraw: Redraw = .now) {
        library.forget(voice.id)
        persist()
        apply(redraw, meetings: voice.meetingIDs,
              repoint: voice.meetingIDs.map { Repoint(meetingID: $0, from: voice.id, to: nil) })
    }

    /// Deletes every fingerprint and sample. Transcripts fall back to "Speaker 1, 2…".
    /// The library itself is dropped here; walking every meeting and redrawing it
    /// is the slow part, so that runs off the main thread like `apply(.background)`.
    func forgetAll() {
        let meetings = voices.flatMap(\.meetingIDs)
        let dir = Paths.voicesDir
        let myName = Pref.myNameOrDefault
        try? FileManager.default.removeItem(at: dir)
        library = VoiceLibrary()
        voices = []
        enqueue(meetings: meetings, myName: myName) {
            for m in Library.loadAll() where FileManager.default.fileExists(atPath: m.speakersURL.path) {
                if var map = MeetingVoices.load(for: m) {
                    for i in map.speakers.indices { map.speakers[i].voiceID = nil }
                    try? map.save(for: m)
                }
            }
        }
    }

    // MARK: Samples

    func togglePlay(_ voice: Voice) {
        if playing == voice.id {
            player?.stop()
            playing = nil
            return
        }
        guard let sample = voice.sample else { return }
        do {
            player = try AVAudioPlayer(contentsOf: Paths.voicesDir.appendingPathComponent(sample))
            player?.play()
            playing = voice.id
            let length = player?.duration ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.1) { [weak self] in
                if self?.playing == voice.id { self?.playing = nil }
            }
        } catch {
            NSLog("Ata: could not play sample: \(error.localizedDescription)")
        }
    }

    // MARK: Private

    private func persist() {
        do { try library.save() } catch { NSLog("Ata: could not save voices: \(error.localizedDescription)") }
        if voices != library.voices { voices = library.voices }
    }

    /// A meeting whose speakers pointed at one voice and now point at another, or none.
    private struct Repoint {
        let meetingID: String
        let from: UUID
        let to: UUID?
    }

    /// Brings the meetings a change touched into line with the library, which is
    /// already saved. In the background, each change waits for the one before: two
    /// quick renames must not finish in the wrong order.
    /// This meeting now, every other meeting afterwards.
    static func split(_ meetings: [String], focus: String) -> (now: [String], later: [String]) {
        (meetings.filter { $0 == focus }, meetings.filter { $0 != focus })
    }

    private func apply(_ redraw: Redraw, meetings: [String], repoint: [Repoint] = []) {
        let myName = Pref.myNameOrDefault
        switch redraw {
        case .now:
            Self.write(repoint, meetings: meetings, myName: myName)
            noteRedrawFinished()
        case .background:
            enqueue(repoint, meetings: meetings, myName: myName)
        case .focused(let id):
            let parts = Self.split(meetings, focus: id)
            Self.write(repoint.filter { $0.meetingID == id }, meetings: parts.now, myName: myName)
            let laterRepoint = repoint.filter { $0.meetingID != id }
            if parts.later.isEmpty, laterRepoint.isEmpty {
                noteRedrawFinished()
            } else {
                enqueue(laterRepoint, meetings: parts.later, myName: myName)
            }
        }
    }

    /// Each change waits for the one before: two quick renames must not finish
    /// in the wrong order. `prepare` runs on the background thread first, for
    /// Forget all's rewrite of every speakers file.
    private func enqueue(_ repoint: [Repoint] = [], meetings: [String], myName: String,
                         prepare: @escaping @Sendable () -> Void = {}) {
        let previous = redraws
        redraws = Task.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            prepare()
            Self.write(repoint, meetings: meetings, myName: myName)
            await self?.noteRedrawFinished()
        }
    }

    private func noteRedrawFinished() {
        redrawsDone &+= 1
    }

    private nonisolated static func write(_ repoint: [Repoint], meetings: [String], myName: String) {
        for change in repoint {
            guard let m = Library.load(change.meetingID), var map = MeetingVoices.load(for: m) else { continue }
            for i in map.speakers.indices where map.speakers[i].voiceID == change.from {
                map.speakers[i].voiceID = change.to
            }
            try? map.save(for: m)
        }
        rerender(meetings: meetings, myName: myName)
    }

    private nonisolated static func rerender(meetings ids: [String], myName: String) {
        for id in Set(ids) {
            guard let m = Library.load(id), m.status == .done else { continue }
            try? Transcriber.rerender(m, myName: myName)
        }
    }

    private func rerender(meetings ids: [String]) {
        Self.rerender(meetings: ids, myName: Pref.myNameOrDefault)
    }
}

/// Cuts a few seconds of one speaker out of a recording, for the play button.
enum VoiceSamples {
    /// An enrolment clip as that voice's sample, so the People tab can play back
    /// what Ata learned you from. The clip itself is a temporary file the caller
    /// deletes; this is a compressed copy.
    static func keep(clip: URL, voice: UUID, maxSeconds: Double = 6) async -> String? {
        try? CloudLibrary.createFolder(Paths.voicesDir)
        let name = "\(voice.uuidString).m4a"
        let out = Paths.voicesDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)

        let asset = AVURLAsset(url: clip)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 1000))
        return await AudioFiles.runExport(session, to: out) == nil ? name : nil
    }

    /// The longest turn of `label`, up to `maxSeconds`, as an m4a in the voices folder.
    static func extract(label: String, turns: [SpeakerTurn], from audio: URL, voice: UUID,
                        maxSeconds: Double = 6) async -> String? {
        guard let best = turns.filter({ $0.label == label }).max(by: { ($0.end - $0.start) < ($1.end - $1.start) }),
              best.end - best.start >= 1_500 else { return nil }
        let start = Double(best.start) / 1000
        let length = min(maxSeconds, Double(best.end - best.start) / 1000)

        try? CloudLibrary.createFolder(Paths.voicesDir)
        let name = "\(voice.uuidString).m4a"
        let out = Paths.voicesDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)

        let asset = AVURLAsset(url: audio)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000),
                                        duration: CMTime(seconds: length, preferredTimescale: 1000))
        return await AudioFiles.runExport(session, to: out) == nil ? name : nil
    }
}
