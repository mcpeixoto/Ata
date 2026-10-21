import AppKit
import AVFoundation
import SwiftUI

/// Finds who spoke when in a track, and a voice fingerprint for each speaker.
/// The implementation is chosen in Diarization.swift.
protocol Diarizer {
    /// Speaker turns and one embedding per speaker label.
    func diarize(_ wav: URL) async throws -> (turns: [SpeakerTurn], embeddings: [String: [Float]])
    /// One embedding for a single-speaker track (your microphone).
    func embed(_ wav: URL) async throws -> [Float]?
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
    var named: [Voice] { voices.filter { $0.name != nil && !$0.isMe }.sorted { $0.meetings > $1.meetings } }
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

    func removeMeeting(_ meetingID: String) {
        library = VoiceLibrary()
        for voice in library.removeMeeting(meetingID) {
            if let sample = voice.sample { try? FileManager.default.removeItem(at: Paths.voicesDir.appendingPathComponent(sample)) }
        }
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

    func forget(_ voice: Voice) {
        if let sample = voice.sample { try? FileManager.default.removeItem(at: Paths.voicesDir.appendingPathComponent(sample)) }
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
        session.outputURL = out
        session.outputFileType = .m4a
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 1000),
                                        duration: CMTime(seconds: length, preferredTimescale: 1000))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        return session.status == .completed ? name : nil
    }
}
