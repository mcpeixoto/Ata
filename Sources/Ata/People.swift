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

    private var library = VoiceLibrary()
    private var player: AVAudioPlayer?

    var enabled: Bool { Pref.d.bool(forKey: Pref.recogniseVoices) }

    var worthAsking: [Voice] { library.worthAsking }
    var named: [Voice] {
        voices.filter { $0.name != nil && !$0.isMe && !$0.isExcluded }.sorted { $0.meetings > $1.meetings }
    }
    var me: Voice? { voices.first(where: \.isMe) }

    func reload() {
        library = VoiceLibrary()
        voices = library.voices
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
    func enrolMe(embedding: [Float], clip: URL) {
        library = VoiceLibrary()
        let voice = library.enrolMe(embedding: embedding)
        persist()
        Task { @MainActor in
            if let sample = await VoiceSamples.keep(clip: clip, voice: voice.id) {
                self.setSample(voice.id, file: sample)
            }
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

    func rename(_ voice: Voice, to name: String) {
        library.rename(voice.id, to: name)
        persist()
        rerender(meetings: voice.meetingIDs)
    }

    func merge(_ source: Voice, into target: Voice) {
        // Meetings that pointed at the source now point at the target.
        for id in source.meetingIDs { repoint(meetingID: id, from: source.id, to: target.id) }
        library.merge(source.id, into: target.id)
        persist()
        rerender(meetings: source.meetingIDs + target.meetingIDs)
    }

    /// Stop asking for this voice's name.
    func dismiss(_ voice: Voice, _ on: Bool = true) {
        library.setDismissed(voice.id, on)
        persist()
    }

    /// "This voice is me", or no longer me: the next meeting in the room knows
    /// which of its speakers is you. Transcripts are redrawn because the voice
    /// leaves, or rejoins, the people listed in them.
    func setMe(_ voice: Voice, _ on: Bool) {
        library.setMe(voice.id, on)
        persist()
        rerender(meetings: voice.meetingIDs)
    }

    /// Leave this voice out of every transcript, or put it back; transcripts are redrawn.
    func setExcluded(_ voice: Voice, _ on: Bool) {
        library.setExcluded(voice.id, on)
        persist()
        rerender(meetings: voice.meetingIDs)
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
        Array(voices.filter { $0.name == nil && !$0.isMe && !$0.isDismissed && !$0.isExcluded
            && $0.meetings < VoiceLibrary.askAfterMeetings }
            .sorted { $0.lastSeen > $1.lastSeen }
            .prefix(Self.heardOnceShown))
    }

    /// Voices that are neither named nor asked about: dismissed, or left out.
    var hidden: [Voice] {
        voices.filter { !$0.isMe && ($0.isExcluded || ($0.name == nil && $0.isDismissed)) }
            .sorted { $0.meetings > $1.meetings }
    }

    /// The voice's file and sample go with it.
    func forget(_ voice: Voice) {
        for id in voice.meetingIDs { repoint(meetingID: id, from: voice.id, to: nil) }
        library.forget(voice.id)
        persist()
        rerender(meetings: voice.meetingIDs)
    }

    /// Deletes every fingerprint and sample. Transcripts fall back to "Speaker 1, 2…".
    func forgetAll() {
        let meetings = voices.flatMap(\.meetingIDs)
        try? FileManager.default.removeItem(at: Paths.voicesDir)
        for m in Library.loadAll() where FileManager.default.fileExists(atPath: m.speakersURL.path) {
            if var map = MeetingVoices.load(for: m) {
                for i in map.speakers.indices { map.speakers[i].voiceID = nil }
                try? map.save(for: m)
            }
        }
        library = VoiceLibrary()
        voices = []
        rerender(meetings: meetings)
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
        voices = library.voices
    }

    private func repoint(meetingID: String, from old: UUID, to new: UUID?) {
        guard let m = Library.loadAll().first(where: { $0.id == meetingID }),
              var map = MeetingVoices.load(for: m) else { return }
        for i in map.speakers.indices where map.speakers[i].voiceID == old { map.speakers[i].voiceID = new }
        try? map.save(for: m)
    }

    private func rerender(meetings ids: [String]) {
        let wanted = Set(ids)
        let myName = Pref.myNameOrDefault
        for m in Library.loadAll() where wanted.contains(m.id) && m.status == .done {
            try? Transcriber.rerender(m, myName: myName)
        }
    }
}

/// Cuts a few seconds of one speaker out of a recording, for the play button.
enum VoiceSamples {
    /// An enrolment clip as that voice's sample, so the People tab can play back
    /// what Ata learned you from. The clip itself is a temporary file the caller
    /// deletes; this is a compressed copy.
    static func keep(clip: URL, voice: UUID, maxSeconds: Double = 6) async -> String? {
        try? FileManager.default.createDirectory(at: Paths.voicesDir, withIntermediateDirectories: true)
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

        try? FileManager.default.createDirectory(at: Paths.voicesDir, withIntermediateDirectories: true)
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
