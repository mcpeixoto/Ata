import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// "System Audio Recording Only" — the macOS permission for what Ata actually
/// does with the Mac's output: record the sound, never the screen.
///
/// Apple has no public API to read or request it ahead of time; the system
/// asks on the first capture. Ata uses the TCC framework's own entry points,
/// loaded at runtime, so it can show the real state in the welcome window and
/// ask up front. If a future macOS removes them, `status` is `.unknown` and the
/// system's prompt on first capture takes over.
enum SystemAudioPermission {
    enum Status: Equatable { case authorized, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let tcc: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: Preflight? = {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: Preflight.self)
    }()

    private static let request: Request? = {
        guard let tcc, let sym = dlsym(tcc, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: Request.self)
    }()

    /// Whether Ata can show the prompt itself, ahead of the first recording.
    static var canAsk: Bool { request != nil }

    static var status: Status {
        guard let preflight else { return .unknown }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt (with Info.plist's NSAudioCaptureUsageDescription).
    /// Calls back on the main queue. Returns false right away if it can't ask.
    @discardableResult
    static func ask(_ done: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let request else { return false }
        request(service, nil) { granted in DispatchQueue.main.async { done(granted) } }
        return true
    }
}

enum SystemAudioError: LocalizedError {
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let code): return L("System audio: %@ failed (%d).", step, Int(code))
        }
    }
}

/// Captures everything the Mac plays through a Core Audio process tap
/// (macOS 14.2+): a global tap, minus Ata's own sound, inside a private
/// aggregate device clocked by the current output device.
///
/// This replaces ScreenCaptureKit, which needed *Screen Recording* permission
/// for what is only audio — and only reported that permission after a
/// relaunch, so the welcome window kept asking for something already granted.
final class SystemAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private var formats: FormatBox?

    /// The tap's current format. Read on the audio thread for every buffer and
    /// written by the property listener, so it needs a lock of its own.
    final class FormatBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _format: AVAudioFormat
        init(_ format: AVAudioFormat) { _format = format }
        var format: AVAudioFormat { lock.lock(); defer { lock.unlock() }; return _format }
        func set(_ format: AVAudioFormat) { lock.lock(); _format = format; lock.unlock() }
    }

    /// What the tap says it is delivering, now.
    private func readFormat() throws -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        let status = Self.get(tapID, kAudioTapPropertyFormat, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.coreAudio("read tap format", status)
        }
        return format
    }

    /// What a tap reports before it is put inside its aggregate device, and
    /// after. They ought to match. When they do not, the difference is exactly
    /// what used to be frozen into every buffer of a recording — so this is
    /// printed by `--diagnose`, where it can be read off a real Mac rather than
    /// reasoned about.
    static func formatProbe() -> (before: String, after: String, clock: String?)? {
        let tap = SystemAudioTap()
        defer { tap.stop() }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Ata format probe"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(description, &tap.tapID) == noErr,
              let before = try? tap.readFormat(),
              let output = try? defaultOutputUID() else { return nil }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ata format probe",
            kAudioAggregateDeviceUIDKey: "ai.interactive.ata.probe.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &tap.aggregateID) == noErr,
              let after = try? tap.readFormat() else { return nil }
        func say(_ f: AVAudioFormat) -> String {
            "\(Int(f.sampleRate)) Hz × \(f.channelCount) \(f.isInterleaved ? "interleaved" : "planar")"
        }
        let clock = nominalRate(tap.aggregateID).map { "\(Int($0)) Hz" }
        return (say(before), say(after), clock)
    }

    /// A PCM buffer whose layout is the buffer list's, not merely the format
    /// the tap advertised.
    ///
    /// `AVAudioPCMBuffer(bufferListNoCopy:)` returns nil unless the list has
    /// exactly the shape the format describes. That nil used to drop the
    /// callback, and the writer filled the hole with silence — a stretch of the
    /// other side of the call with nothing in it, in a file that was still the
    /// right length. Frame count, when the shape does match, is
    /// `mDataByteSize / mBytesPerFrame`. A buffer that is only half as long as
    /// the time since the last one is the recording at double speed; the writer
    /// relabels those samples with the rate they actually arrived at, which the
    /// silence used to hide.
    static func pcmBuffer(from list: UnsafePointer<AudioBufferList>, claimed: AVAudioFormat) -> AVAudioPCMBuffer? {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, first.mData != nil, first.mDataByteSize > 0 else { return nil }
        let channels = abl.reduce(0) { $0 + Int($1.mNumberChannels) }
        let interleaved = abl.count == 1
        let matches = channels == Int(claimed.channelCount) && interleaved == claimed.isInterleaved
        if matches, let pcm = AVAudioPCMBuffer(pcmFormat: claimed, bufferListNoCopy: list, deallocator: nil),
           pcm.frameLength > 0 {
            return pcm
        }
        let common: AVAudioCommonFormat = claimed.commonFormat == .pcmFormatInt16 ? .pcmFormatInt16 : .pcmFormatFloat32
        let bytesPerSample = common == .pcmFormatInt16 ? 2 : 4
        let bytesPerFrame = bytesPerSample * max(Int(first.mNumberChannels), 1)
        let frames = Int(first.mDataByteSize) / bytesPerFrame
        guard channels > 0, channels <= 32, frames > 0,
              let format = AVAudioFormat(commonFormat: common, sampleRate: claimed.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: interleaved),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        copy.frameLength = AVAudioFrameCount(frames)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard dst.count == abl.count else { return nil }
        for i in 0..<abl.count {
            guard let from = abl[i].mData, let into = dst[i].mData else { return nil }
            let n = min(Int(abl[i].mDataByteSize), Int(dst[i].mDataByteSize))
            guard n > 0 else { return nil }
            into.copyMemory(from: from, byteCount: n)
        }
        return copy
    }

    /// The rate samples are delivered at. The tap property can keep claiming
    /// 48 kHz after the device it is clocked by has dropped to 16.
    private func formatOnClock(_ tapFormat: AVAudioFormat) -> AVAudioFormat {
        guard let clock = Self.nominalRate(aggregateID),
              abs(clock - tapFormat.sampleRate) / tapFormat.sampleRate > 0.02,
              let adjusted = AVAudioFormat(commonFormat: tapFormat.commonFormat,
                                           sampleRate: clock,
                                           channels: tapFormat.channelCount,
                                           interleaved: tapFormat.isInterleaved) else { return tapFormat }
        NSLog("Ata: the system tap says \(Int(tapFormat.sampleRate)) Hz but its device runs at "
              + "\(Int(clock)) Hz — recording at the device clock")
        return adjusted
    }

    private static func nominalRate(_ object: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    /// The format the tap is delivering, for a recording that came out wrong.
    var formatDescription: String? {
        formats.map { "\(Int($0.format.sampleRate)) Hz × \($0.format.channelCount)" }
    }

    /// Starts delivering buffers, with the host time of their first sample when known.
    func start(queue: DispatchQueue, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Double?) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Ata"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        let output = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ata system audio",
            kAudioAggregateDeviceUIDKey: "ai.interactive.ata.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        // Read *after* the aggregate device exists, not before.
        //
        // A tap is clocked by the device it ends up inside. Asked before that
        // device is built, it answers with a format it is not going to deliver —
        // and the answer was being frozen into the callback for the whole
        // recording. Every buffer then carried the wrong sample rate, so the
        // converter resampled by the wrong ratio and the track came out at the
        // wrong speed: unlistenable, and transcribed to nonsense, with nothing
        // anywhere to say so. It only showed when the output device disagreed
        // with the tap's first answer, which is why it came and went.
        // The tap's own answer, then the clock it is actually running on. Drift
        // compensation delivers samples at the aggregate device's rate, which a
        // Bluetooth headset can change without the tap property ever updating.
        let box = FormatBox(formatOnClock(try readFormat()))
        formats = box

        // And it can still change under us — the output device switches when
        // headphones go in. Follow it rather than trusting the first answer.
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let tap = try? self.readFormat() else { return }
            let now = self.formatOnClock(tap)
            if now != box.format {
                NSLog("Ata: the system audio tap changed format: \(box.format.sampleRate) Hz × "
                      + "\(box.format.channelCount) → \(now.sampleRate) Hz × \(now.channelCount)")
                box.set(now)
            }
        }
        if AudioObjectAddPropertyListenerBlock(tapID, &formatAddress, queue, listener) == noErr {
            formatListener = listener
        }

        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, time, _, _ in
            // The buffer only lives for this callback; the writer converts it before returning.
            // The tap's format describes what it *claims* to deliver. The list is
            // what this callback actually handed over, and the two can disagree.
            guard let pcm = Self.pcmBuffer(from: input, claimed: box.format) else { return }
            let t = time.pointee
            let host: Double? = t.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: t.mHostTime) : nil
            onBuffer(pcm, host)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
        if let formatListener, tapID != kAudioObjectUnknown {
            var addr = Self.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tapID, &addr, nil, formatListener)
        }
        formatListener = nil
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    // MARK: - Core Audio helpers

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw SystemAudioError.coreAudio(step, status)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// Plain values only: object references (CFString) go through `readString`.
    private static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                _ value: inout T) -> OSStatus {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    }

    /// Ata's own audio object, so playing a voice sample never ends up in a recording.
    private static func ownProcessObject() -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func defaultOutputUID() throws -> String {
        guard let device = defaultOutputDevice() else { throw SystemAudioError.coreAudio("find output device", -1) }
        var addr = address(kAudioDevicePropertyDeviceUID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uid: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value = uid?.takeRetainedValue() else {
            throw SystemAudioError.coreAudio("read output device", status)
        }
        return value as String
    }

    /// Calls `changed` on the main queue whenever the system output device
    /// changes (headphones plugged in, AirPods connecting), so capture can be
    /// rebuilt on the new device. Returns a token for `stopWatching`.
    static func watchOutputDevice(_ changed: @escaping @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        return block
    }

    static func stopWatching(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }
}
