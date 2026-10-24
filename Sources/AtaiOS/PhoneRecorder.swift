import AVFoundation

enum PhoneRecorderError: LocalizedError {
    case micDenied, noMic, alreadyRecording

    var errorDescription: String? {
        switch self {
        case .micDenied: return L("Ata does not have access to the microphone.")
        case .noMic: return L("No active microphone was found.")
        case .alreadyRecording: return L("Ata is already recording.")
        }
    }
}

/// Records the iPhone's microphone into mic.wav, 16 kHz mono, through the same
/// `WavWriter` as the Mac, for hours and with the screen locked (the app has the
/// `audio` background mode).
///
/// Interruptions pause and resume into the same file. There is one track, so
/// nothing has to stay aligned with anything: the time spent interrupted is left
/// out of the file rather than filled with silence.
@MainActor
final class PhoneRecorder {
    private(set) var state = RecorderState()
    /// The recording in progress, still in its staging folder.
    private(set) var meeting: Meeting?
    private(set) var folder: URL?
    private(set) var mode: RecordingMode = .inPerson

    /// Every phase change, so the store and the Live Activity follow along.
    var onPhaseChange: ((RecorderState.Phase) -> Void)?
    /// A problem worth showing while recording; nil when all is well again.
    var onWarning: ((String?) -> Void)?

    private var engine: AVAudioEngine?
    private var writer: WavWriter?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    private var retries = 0

    /// Seconds of audio in the file so far.
    var recordedSeconds: Double { writer?.duration ?? 0 }
    var level: Float { state.isCapturing ? (writer?.level ?? 0) : 0 }

    static func requestPermission() async -> Bool {
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
    }

    // MARK: Start and stop

    func start(mode: RecordingMode) throws -> Meeting {
        guard !state.isActive else { throw PhoneRecorderError.alreadyRecording }
        let staged = try StagingFolder.create(app: mode.meetingApp)
        do {
            // No host times are passed in (see above), so the start time is never used.
            writer = try WavWriter(url: staged.folder.appendingPathComponent("mic.wav"), startHostSeconds: 0)
            self.mode = mode
            meeting = staged.meeting
            folder = staged.folder
            try apply(state.handle(.start))
        } catch {
            // Nothing was recorded: leave no empty meeting behind.
            stopEngine()
            writer?.close()
            writer = nil
            meeting = nil
            folder = nil
            state = RecorderState()
            try? FileManager.default.removeItem(at: staged.folder)
            throw error
        }
        installObservers()
        onPhaseChange?(state.phase)
        return staged.meeting
    }

    /// Stops, closes the file, saves meeting.json with `bookmarks` and moves the
    /// recording into the meetings folder, queued for transcription. Nil when
    /// nothing was recording. If the move fails (`moved` is false), the folder
    /// stays in staging, where it is still listed and transcribed, and the next
    /// launch moves it.
    func stop(bookmarks: [Bookmark]) -> (meeting: Meeting, moved: Bool)? {
        guard state.isActive, var m = meeting, let folder else { return nil }
        removeObservers()
        let seconds = recordedSeconds
        try? apply(state.handle(.stop))
        writer = nil
        meeting = nil
        self.folder = nil
        onPhaseChange?(state.phase)

        m.endedAt = Date()
        m.duration = seconds
        let hasAudio = Paths.fileSize(folder.appendingPathComponent("mic.wav")) > 44
        m.status = hasAudio ? .pending : .failed
        if !hasAudio { m.error = L("Empty recording") }
        if !bookmarks.isEmpty { m.bookmarks = bookmarks }
        return StagingFolder.publish(m)
    }

    /// Carries on after an interruption that iOS did not hand back by itself.
    func resume() {
        handle(.resume)
    }

    // MARK: State machine

    private func handle(_ event: RecorderState.Event) {
        let before = state.phase
        let effects = state.handle(event)
        do {
            try apply(effects)
            retries = 0
            onWarning?(nil)
        } catch {
            NSLog("Ata: \(event): \(error.localizedDescription)")
            retryCapture()
        }
        if state.phase != before { onPhaseChange?(state.phase) }
    }

    private func apply(_ effects: [RecorderState.Effect]) throws {
        let session = AVAudioSession.sharedInstance()
        for effect in effects {
            switch effect {
            case .beginCapture:
                try configureSession()
                try startEngine()
            case .pauseCapture:
                stopEngine()
            case .resumeCapture:
                try session.setActive(true)
                try startEngine()
            case .restartCapture:
                stopEngine()
                try startEngine()
            case .rebuildSession:
                stopEngine()
                try configureSession()
                try startEngine()
            case .finishCapture:
                stopEngine()
                writer?.close()
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                // Back to plain playback, so meetings play with the silent switch on.
                try? session.setCategory(.playback, mode: .spokenAudio)
            }
        }
    }

    /// The input went away and the new one isn't ready yet (AirPods mid-switch):
    /// try again, a little later each time, for as long as the recording lasts.
    private func retryCapture() {
        guard state.isCapturing else { return }
        retries += 1
        onWarning?(L("No microphone — retrying…"))
        let delay = min(5.0, 0.5 * Double(retries))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.isCapturing, self.engine == nil else { return }
                self.handle(.mediaServicesReset)
            }
        }
    }

    // MARK: Audio

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Bluetooth lets AirPods be the microphone; without headphones the
        // bottom speaker, not the earpiece, plays anything Ata plays.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func startEngine() throws {
        guard let writer else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if mode.usesVoiceProcessing {
            try input.setVoiceProcessingEnabled(true)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw PhoneRecorderError.noMic }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTap(writer))
        engine.prepare()
        try engine.start()
        self.engine = engine
        writer.touch()

        // The engine stops itself when its input changes; build a new one for the new input.
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.routeChanged) }
        }
    }

    /// Made off the main actor: the block runs on the audio thread. No host time,
    /// so the writer never pads an interruption with silence.
    nonisolated private static func makeTap(_ writer: WavWriter) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            writer.append(buffer, hostSeconds: nil)
        }
    }

    private func stopEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: Notifications

    private func installObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: .main) { [weak self] note in
            guard let event = Self.interruptionEvent(note.userInfo) else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // A running engine reports its own change; only a stopped one needs restarting here.
                guard let self, self.state.isCapturing, self.engine?.isRunning != true else { return }
                self.handle(.routeChanged)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.mediaServicesReset) }
        })
    }

    private func removeObservers() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    nonisolated private static func interruptionEvent(_ info: [AnyHashable: Any]?) -> RecorderState.Event? {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            return .interruptionBegan
        case .ended:
            let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}
