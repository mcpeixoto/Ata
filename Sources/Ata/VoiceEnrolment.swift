import AVFoundation
import Foundation

/// Reads your voice once, so Ata knows which speaker is you before it has ever
/// heard you in a meeting.
///
/// Everything else learns you the long way round. On a call the Mac can take the
/// microphone track, which is you by construction. In the room there is one
/// microphone and several people on it, and Ata has to guess which speaker is
/// you — a guess it refuses to learn from, because learning the wrong one would
/// put your name on someone else for good. That leaves a loop with no way in:
/// no fingerprint of you, so no recognition, so still no fingerprint.
///
/// Twenty seconds of reading breaks it. The clip is diarized like any other
/// recording, its main speaker's embedding becomes a voice marked `isMe`, and
/// from the next meeting on Ata knows you in a room full of people.
@MainActor
final class VoiceEnrolment: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        /// Diarizing the clip, which takes a few seconds on a phone.
        case learning
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Seconds recorded so far, for the countdown.
    @Published private(set) var seconds: Double = 0
    /// 0–1, for a live level meter.
    @Published private(set) var level: Float = 0

    /// How long you read for. The pipeline will not fingerprint a speaker it has
    /// heard for under ten seconds, and a reader pauses; twenty leaves room for
    /// the pauses and still clears the floor.
    static let targetSeconds: Double = 20

    /// What to read. Long enough to fill the time at a normal pace, and plain
    /// enough that nobody has to perform it.
    static var prompt: String {
        L("Ata is listening to the way I speak, so it can tell my voice from everyone else's in a meeting. I talk at my normal pace, in my normal voice, until this is done.")
    }

    private var engine: AVAudioEngine?
    private var writer: WavWriter?
    private var clip: URL?
    private var ticker: Task<Void, Never>?

    deinit { ticker?.cancel() }

    // MARK: Recording

    func start() {
        guard phase != .recording, phase != .learning else { return }
        phase = .recording
        seconds = 0
        level = 0
        Task { await begin() }
    }

    /// A meeting being recorded owns the microphone. Taking it for twenty seconds
    /// would cut a hole in that recording, and audio is never worth a feature.
    static var busyRecording: Bool {
        #if os(iOS)
        return PhoneStore.shared.isRecording
        #else
        return AppStore.shared.phase != .idle
        #endif
    }

    private func begin() async {
        guard !Self.busyRecording else {
            phase = .failed(L("Ata is recording a meeting. Try again when it has stopped."))
            return
        }
        guard await Self.microphoneGranted() else {
            phase = .failed(L("Ata needs the microphone to hear your voice."))
            return
        }
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ata-enrol-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("me.wav")
            // No host time: the tap passes none either, so the writer never pads
            // an interruption with silence.
            let writer = try WavWriter(url: url, startHostSeconds: 0)
            self.writer = writer
            self.clip = url
            try startEngine(writing: writer)
            tick()
        } catch {
            cleanUp()
            phase = .failed(error.localizedDescription)
        }
    }

    private static func microphoneGranted() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { c in
                AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
            }
        default:
            return false
        }
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    private func startEngine(writing writer: WavWriter) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw EnrolmentError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTap(writer))
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Made off the main actor: the block runs on the audio thread.
    nonisolated private static func makeTap(_ writer: WavWriter) -> AVAudioNodeTapBlock {
        return { buffer, _ in writer.append(buffer, hostSeconds: nil) }
    }

    /// Drives the countdown, and stops on its own at `targetSeconds` so nobody
    /// has to watch for the end.
    private func tick() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, self.phase == .recording, let writer = self.writer else { return }
                self.seconds = writer.duration
                self.level = writer.level
                if writer.duration >= Self.targetSeconds {
                    self.finish()
                    return
                }
            }
        }
    }

    /// Stops early. Under half the time is too little to fingerprint, so it is
    /// thrown away rather than saved as a poor copy of your voice.
    func cancel() {
        let enough = (writer?.duration ?? 0) >= Self.targetSeconds / 2
        if phase == .recording, enough {
            finish()
        } else {
            cleanUp()
            phase = .idle
            seconds = 0
            level = 0
        }
    }

    // MARK: Learning

    private func finish() {
        ticker?.cancel()
        ticker = nil
        stopEngine()
        writer?.close()
        guard let clip, phase == .recording else { cleanUp(); return }
        phase = .learning
        Task { await learn(from: clip) }
    }

    private func learn(from clip: URL) async {
        guard let diarizer = Diarization.current else {
            cleanUp()
            phase = .failed(L("Voice recognition isn't available on this device."))
            return
        }
        do {
            // A clip you recorded of yourself is not a guess, so the floor the
            // meeting pipeline keeps does not apply: whatever is here is your voice.
            guard let embedding = try await diarizer.embed(clip) else {
                cleanUp()
                phase = .failed(L("Ata couldn't hear enough speech. Try again somewhere quieter."))
                return
            }
            await PeopleModel.shared.enrolMe(embedding: embedding, clip: clip)
            cleanUp()
            phase = .done
        } catch {
            cleanUp()
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Tidying up

    private func stopEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    private func cleanUp() {
        ticker?.cancel()
        ticker = nil
        stopEngine()
        writer?.close()
        writer = nil
        if let clip {
            try? FileManager.default.removeItem(at: clip.deletingLastPathComponent())
        }
        clip = nil
    }
}

enum EnrolmentError: LocalizedError {
    case noMicrophone

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return L("No microphone to record from.")
        }
    }
}
