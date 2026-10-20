import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case micDenied, screenDenied, noDisplay, noMic

    var errorDescription: String? {
        switch self {
        case .micDenied: return L("Ata does not have access to the microphone.")
        case .screenDenied: return L("Ata does not have access to system audio (Screen & System Audio Recording).")
        case .noDisplay: return L("No display was found to capture system audio from.")
        case .noMic: return L("No active microphone was found.")
        }
    }
}

/// Thread-safe box that shares the system-audio writer with ScreenCaptureKit's queue.
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
///  - system.wav → everything the Mac plays (ScreenCaptureKit). Reconnects with backoff when
///                 capture drops (for example after the Mac sleeps).
@MainActor
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var mic: WavWriter?
    nonisolated private let sysBox = WriterBox()
    var sys: WavWriter? { sysBox.writer }

    private var engine: AVAudioEngine?
    private var stream: SCStream?
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
        await teardown()
        return duration
    }

    private func teardown() async {
        running = false
        watchdog?.invalidate(); watchdog = nil
        for o in observers {
            NotificationCenter.default.removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers.removeAll()
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
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.screenDenied
        }
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.width = 2 // we do not want video
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 3
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sysQueue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sysQueue)
        do {
            try await s.startCapture()
        } catch {
            throw RecorderError.screenDenied
        }
        stream = s
        sys?.touch()
    }

    private func stopSystem() async {
        if let s = stream {
            stream = nil
            try? await s.stopCapture()
        }
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

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let writer = sysBox.writer else { return }
        let t = sampleBuffer.presentationTimeStamp.seconds
        try? sampleBuffer.withAudioBufferList { abl, _ in
            guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                             channels: asbd.mChannelsPerFrame),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: abl.unsafePointer)
            else { return }
            writer.append(pcm, hostSeconds: t.isFinite ? t : nil)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            NSLog("Ata: system capture stopped: \(error.localizedDescription)")
            self.stream = nil
            self.restartSystem()
        }
    }

    // MARK: - Watchdog

    private func installObservers() {
        // Depois de o Mac acordar, reiniciar as duas capturas.
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartMic(reason: "wake from sleep")
                self?.restartSystem()
            }
        }
        observers.append(wake)

        // Watchdog: if the microphone stops delivering audio, restart it.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.micRestartPending, let mic = self.mic else { return }
                if Date().timeIntervalSince(mic.lastBufferAt) > 4 {
                    self.restartMic(reason: "microphone not responding")
                }
            }
        }
    }
}
