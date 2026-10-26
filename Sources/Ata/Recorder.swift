import AppKit
import AVFoundation
import CoreAudio
import CoreMedia

enum RecorderError: LocalizedError, Equatable {
    case micDenied, systemAudioDenied, noMic
    case systemAudio(String)

    var errorDescription: String? {
        switch self {
        case .micDenied: return L("Ata does not have access to the microphone.")
        case .systemAudioDenied: return L("Ata does not have access to system audio (System Audio Recording Only).")
        case .noMic: return L("No active microphone was found.")
        case .systemAudio(let detail): return detail
        }
    }

    var isPermission: Bool { self == .micDenied || self == .systemAudioDenied }
}

/// Thread-safe box that shares the system-audio writer with the capture queue.
private final class WriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _writer: WavWriter?
    var writer: WavWriter? {
        get { lock.lock(); defer { lock.unlock() }; return _writer }
        set { lock.lock(); _writer = newValue; lock.unlock() }
    }
}

/// Records two tracks at once and recovers from almost anything on its own:
///  - mic.wav    → your microphone (AVAudioEngine). Restarts when you switch microphones,
///                 when the device disappears, or when it stops delivering audio.
///  - system.wav → everything the Mac plays (a Core Audio process tap). Rebuilt when the output
///                 device changes, after sleep, or when it stops delivering audio.
@MainActor
final class Recorder: NSObject {
    private(set) var mic: WavWriter?
    nonisolated private let sysBox = WriterBox()
    var sys: WavWriter? { sysBox.writer }

    private var engine: AVAudioEngine?
    private var tap: SystemAudioTap?
    private var outputWatcher: AudioObjectPropertyListenerBlock?
    nonisolated private let sysQueue = DispatchQueue(label: "ai.interactive.ata.system-audio", qos: .userInitiated)
    private var running = false
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var micRetry = 0
    private var sysRetry = 0
    private var sysRestarting = false
    private var micRestartPending = false

    /// Status messages for the UI (nil = all good).
    var onWarning: ((String?) -> Void)?

    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    // MARK: - Start / stop

    func start(in dir: URL) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecorderError.micDenied }

        let t0 = Self.hostNow()
        mic = try WavWriter(url: dir.appendingPathComponent("mic.wav"), startHostSeconds: t0)
        sysBox.writer = try WavWriter(url: dir.appendingPathComponent("system.wav"), startHostSeconds: t0)
        running = true

        do {
            try startMic()
            try await startSystem()
        } catch {
            await teardown()
            throw error
        }
        installObservers()
    }

    /// Stops everything, closes the files and returns the recorded duration (s).
    func stop() async -> Double {
        let duration = max(mic?.duration ?? 0, sys?.duration ?? 0)
        formatsSeen = (mic?.inputFormats ?? []) + (sys?.inputFormats ?? [])
        await teardown()
        return duration
    }

    /// The input formats the writers were handed, kept past teardown so the
    /// caller can name them if the recording turns out to be the wrong length.
    private(set) var formatsSeen: [String] = []

    private func teardown() async {
        running = false
        watchdog?.invalidate(); watchdog = nil
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers.removeAll()
        if let outputWatcher { SystemAudioTap.stopWatching(outputWatcher) }
        outputWatcher = nil
        stopMic()
        await stopSystem()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            sysQueue.async { c.resume() } // make sure the last buffer has been written
        }
        mic?.close(); mic = nil
        sysBox.writer?.close(); sysBox.writer = nil
        onWarning?(nil)
    }

    var micLevel: Float { mic?.level ?? 0 }
    var systemLevel: Float { sys?.level ?? 0 }

    // MARK: - Microphone

    private func startMic() throws {
        guard let writer = mic else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecorderError.noMic }

        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTap(writer))
        engine.prepare()
        try engine.start()
        self.engine = engine
        writer.touch()

        let o = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                       object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartMic(reason: "microphone change") }
        }
        observers.append(o)
    }

    /// Created off the MainActor: the block runs on the audio thread.
    nonisolated private static func makeTap(_ writer: WavWriter) -> AVAudioNodeTapBlock {
        return { buffer, when in
            let t: Double? = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
            writer.append(buffer, hostSeconds: t)
        }
    }

    private func stopMic() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func restartMic(reason: String) {
        guard running else { return }
        stopMic()
        do {
            try startMic()
            micRetry = 0
            onWarning?(nil)
        } catch {
            micRetry += 1
            micRestartPending = true
            onWarning?(L("No microphone — retrying…"))
            let delay = min(5.0, 0.5 * Double(micRetry))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    self?.micRestartPending = false
                    self?.restartMic(reason: reason)
                }
            }
        }
    }

    // MARK: - System audio

    private func startSystem() async throws {
        // Never start the tap with the question still open: Core Audio delivers
        // nothing until permission exists, and doesn't resume once it's given.
        if SystemAudioPermission.status == .unknown, SystemAudioPermission.canAsk {
            let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                if !SystemAudioPermission.ask({ c.resume(returning: $0) }) { c.resume(returning: true) }
            }
            if !granted { throw RecorderError.systemAudioDenied }
        }
        guard SystemAudioPermission.status != .denied else { throw RecorderError.systemAudioDenied }
        let box = sysBox
        let tap = SystemAudioTap()
        do {
            try tap.start(queue: sysQueue) { buffer, hostSeconds in
                box.writer?.append(buffer, hostSeconds: hostSeconds)
            }
        } catch {
            throw RecorderError.systemAudio(error.localizedDescription)
        }
        self.tap = tap
        sys?.touch()
    }

    private func stopSystem() async {
        tap?.stop()
        tap = nil
    }

    private func restartSystem() {
        guard running, !sysRestarting else { return }
        sysRestarting = true
        onWarning?(L("Reconnecting system audio…"))
        Task { @MainActor in
            await stopSystem()
            while running {
                do {
                    try await startSystem()
                    sysRetry = 0
                    onWarning?(nil)
                    break
                } catch {
                    sysRetry += 1
                    let delay = min(10.0, Double(sysRetry))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            sysRestarting = false
        }
    }

    // MARK: - Watchdog

    private func installObservers() {
        // After the Mac wakes, restart both captures.
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartMic(reason: "wake from sleep")
                self?.restartSystem()
            }
        }
        observers.append(wake)

        // New output device (headphones, AirPods): the tap's aggregate device was
        // clocked by the old one, so build it again on the new one.
        outputWatcher = SystemAudioTap.watchOutputDevice { [weak self] in
            Task { @MainActor in self?.restartSystem() }
        }

        // Watchdog: if either track stops delivering audio, restart it. The tap
        // delivers silence while nothing plays, so no buffers at all means trouble.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                if !self.micRestartPending, let mic = self.mic, Date().timeIntervalSince(mic.lastBufferAt) > 4 {
                    self.restartMic(reason: "microphone not responding")
                }
                if !self.sysRestarting, let sys = self.sys, Date().timeIntervalSince(sys.lastBufferAt) > 6 {
                    self.restartSystem()
                }
            }
        }
    }
}
