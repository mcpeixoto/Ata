import AVFoundation

enum WatchRecorderError: LocalizedError {
    case micDenied, couldNotStart

    var errorDescription: String? {
        switch self {
        case .micDenied: return L("Allow Ata to use the microphone in Settings to record.")
        case .couldNotStart: return L("The recording could not start.")
        }
    }
}

/// Records the Watch's microphone into a 16 kHz mono WAV, the iPhone's format.
/// A recording started on screen carries on with the wrist down: the app has
/// the `audio` background mode.
///
/// Interruptions (a call, Siri) pause and resume into the same file, decided by
/// the iPhone's `RecorderState`. The recording in progress is noted in
/// `current.json` next to it, so one cut short by a flat battery is still
/// found and sent on the next launch.
@MainActor
final class WatchRecorder: NSObject {
    struct Recording: Codable, Equatable {
        var info: WatchRecordingInfo
        /// The file's name in `folder`.
        var file: String
    }

    let folder: URL
    private(set) var state = RecorderState()
    private(set) var clock = WatchClock()
    private(set) var current: Recording?

    /// Phase, time or bookmarks changed.
    var onChange: (() -> Void)?
    /// watchOS stopped the recorder by itself; the model finishes the recording
    /// as if you had stopped it, so what was recorded is kept and sent.
    var onEndedBySystem: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var observers: [NSObjectProtocol] = []

    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    init(folder: URL) {
        self.folder = folder
        super.init()
    }

    var isActive: Bool { state.isActive }
    var bookmarks: [Int] { current?.info.bookmarks ?? [] }

    private var currentURL: URL { folder.appendingPathComponent("current.json") }

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

    func start() async throws {
        guard !state.isActive else { return }
        guard await Self.requestPermission() else { throw WatchRecorderError.micDenied }
        guard !state.isActive else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = WatchRecordingInfo(startedAt: Date())
        let file = "\(info.id.uuidString).wav"
        let url = folder.appendingPathComponent(file)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
            let r = try AVAudioRecorder(url: url, settings: Self.settings)
            r.delegate = self
            guard r.record() else { throw WatchRecorderError.couldNotStart }
            recorder = r
        } catch {
            // Nothing was recorded: leave no empty file behind.
            try? session.setActive(false)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        current = Recording(info: info, file: file)
        saveCurrent()
        apply(state.handle(.start))
        installObservers()
        onChange?()
    }

    /// Stops and closes the file. The recording, with its bookmarks, for the
    /// outbox; nil when nothing was recording.
    func stop() -> Recording? {
        guard state.isActive, var finished = current else { return nil }
        removeObservers()
        apply(state.handle(.stop))
        finished.info.duration = clock.elapsed(at: Date())
        recorder?.delegate = nil
        recorder = nil
        current = nil
        clock = WatchClock()
        try? FileManager.default.removeItem(at: currentURL)
        try? AVAudioSession.sharedInstance().setActive(false)
        onChange?()
        return finished
    }

    /// Carries on after an interruption watchOS did not hand back by itself.
    func resume() {
        apply(state.handle(.resume))
        onChange?()
    }

    func bookmark() {
        guard state.isActive, current != nil else { return }
        current?.info.bookmarks.append(Int(clock.elapsed(at: Date()) * 1000))
        saveCurrent()
        onChange?()
    }

    /// A recording that never stopped (the Watch ran out of battery, or Ata was
    /// ended): its file, for the outbox, with the length its size gives. Nil
    /// when there is none.
    func leftover() -> Recording? {
        guard !state.isActive, let data = try? Data(contentsOf: currentURL),
              var found = try? JSONDecoder().decode(Recording.self, from: data) else { return nil }
        let url = folder.appendingPathComponent(found.file)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        try? FileManager.default.removeItem(at: currentURL)
        guard size > 0 else { return nil }
        found.info.duration = max(0, Double(size - 44) / 32_000)
        return found
    }

    private func saveCurrent() {
        guard let current else { return }
        do {
            try JSONEncoder().encode(current).write(to: currentURL, options: .atomic)
        } catch {
            NSLog("Ata: could not note the recording in progress: \(error.localizedDescription)")
        }
    }

    // MARK: State machine

    private func handle(_ event: RecorderState.Event) {
        let before = state.phase
        apply(state.handle(event))
        if state.phase != before { onChange?() }
    }

    private func apply(_ effects: [RecorderState.Effect]) {
        let now = Date()
        for effect in effects {
            switch effect {
            case .beginCapture:
                // start() has the recorder running already.
                clock = WatchClock()
                clock.run(at: now)
            case .pauseCapture:
                recorder?.pause()
                clock.pause(at: now)
            case .resumeCapture, .rebuildSession:
                try? AVAudioSession.sharedInstance().setActive(true)
                if recorder?.record() == true {
                    clock.run(at: now)
                } else {
                    // Still paused, so Resume shows again, rather than a clock
                    // running over nothing. What was recorded stays in the file.
                    NSLog("Ata: the Watch recording could not resume")
                    recorder?.pause()
                    _ = state.handle(.interruptionBegan)
                }
            case .restartCapture:
                // The recorder follows a new input by itself.
                break
            case .finishCapture:
                recorder?.stop()
                clock.pause(at: now)
            }
        }
    }

    private func ended(_ id: ObjectIdentifier) {
        guard let recorder, ObjectIdentifier(recorder) == id, state.isActive else { return }
        NSLog("Ata: watchOS stopped the recording")
        onEndedBySystem?()
    }

    /// The audio system restarted, and the recorder with it: nothing more reaches
    /// the file. Finished like a recording watchOS stopped, so what it holds is kept and sent.
    private func mediaServicesReset() {
        guard state.isActive else { return }
        NSLog("Ata: the audio system restarted during the Watch recording")
        onEndedBySystem?()
    }

    // MARK: Notifications

    private func installObservers() {
        let session = AVAudioSession.sharedInstance()
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                object: session, queue: .main) { [weak self] note in
            guard let event = Self.interruptionEvent(note.userInfo) else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                                                object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mediaServicesReset() }
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

extension WatchRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.ended(id) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor in self.ended(id) }
    }
}
