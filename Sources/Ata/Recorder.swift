import AppKit
import AVFoundation
import CoreAudio
import CoreMedia

/// Whether this recording's microphone is the only one in use: the built-in
/// laptop microphone, or the only input device on the machine. A headset or a
/// second mic is someone choosing a microphone that is just them.
enum InputDevices {
    static var isSolo: Bool {
        guard let device = defaultInput() else { return false }
        if transport(device) == kAudioDeviceTransportTypeBuiltIn { return true }
        return inputDevices().count <= 1
    }

    private static func defaultInput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func transport(_ device: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func inputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { inputChannels($0) > 0 }
    }

    private static func inputChannels(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

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
    private var startedAt = Date()
    /// The "we cannot hear the other side" warning is showing: it clears
    /// itself if their side ever arrives, and never repeats within a call.
    private var silentSystemWarned = false
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
        startedAt = Date()
        silentSystemWarned = false
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
        // Taken before the writers close. The ratio is samples against the
        // clock, counted before the silence that pads a short buffer.
        paces = [mic, sys].compactMap { writer in
            guard let writer else { return nil }
            return CapturePace(track: writer.url.lastPathComponent,
                               deliveryRatio: writer.deliveryRatio,
                               corrected: writer.correctedDelivery,
                               formats: writer.inputFormats,
                               fileSeconds: writer.duration,
                               hostSeconds: writer.hostSpan)
        }
        await teardown()
        return duration
    }

    /// The input formats the writers were handed, kept past teardown so the
    /// caller can name them if the recording turns out to be the wrong length.
    private(set) var formatsSeen: [String] = []

    /// How each track's samples compared with the clock. Empty until `stop`.
    private(set) var paces: [CapturePace] = []

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

    /// Buffers arriving is not the same as a side being captured: a tap pointed
    /// at an output the call is not using delivers silence with perfect
    /// attendance, the watchdog above never fires, and the meeting is filed
    /// with the other side of the call missing from it. Nobody finds that out
    /// until they read the transcript.
    ///
    /// So: half a minute in, if you have clearly been heard and their side has
    /// never risen above digital silence, say so while the call can still be
    /// saved. Their side arriving clears it again. (Levels are on the writer's
    /// ≈ −50 dB…0 dB scale, where silence is 0.)
    private func checkForASilentSide() {
        guard let mic, let sys else { return }
        if sys.peakLevel >= 0.01 {
            if silentSystemWarned {
                silentSystemWarned = false
                onWarning?(nil)
            }
            return
        }
        guard !silentSystemWarned, !sysRestarting,
              Date().timeIntervalSince(startedAt) > 30, mic.peakLevel >= 0.05 else { return }
        silentSystemWarned = true
        onWarning?(L("Ata can't hear the other side — check the call's output device"))
    }

    // MARK: - Microphone

    private func startMic() throws {
        guard let writer = mic else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecorderError.noMic }

        // `nil`, not the format read a moment ago. A cached format is a promise
        // about hardware that may already have changed — and when the two
        // disagree the engine still delivers, tagging every buffer with the
        // format we asked for while the samples are at the device's real rate.
        // The converter then resamples by the wrong ratio and the recording
        // comes out at the wrong speed: unlistenable, transcribed to nonsense,
        // and nothing anywhere says so. Passing nil means the node's own format
        // comes with every buffer, which is the one thing that cannot be stale.
        // The read above stays, but only to tell a missing microphone apart
        // from a working one.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: Self.makeTap(writer))
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
                self.checkForASilentSide()
            }
        }
    }
}
