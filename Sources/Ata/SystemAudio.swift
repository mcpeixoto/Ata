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

    /// Starts delivering buffers, with the host time of their first sample when known.
    func start(queue: DispatchQueue, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, Double?) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Ata"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check("create tap", AudioHardwareCreateProcessTap(description, &tapID))

        var asbd = AudioStreamBasicDescription()
        try check("read tap format", Self.get(tapID, kAudioTapPropertyFormat, &asbd))
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioError.coreAudio("read tap format", -1)
        }

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

        try check("create IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, time, _, _ in
            // The buffer only lives for this callback; the writer converts it before returning.
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            let t = time.pointee
            let host: Double? = t.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: t.mHostTime) : nil
            onBuffer(pcm, host)
        })
        try check("start", AudioDeviceStart(aggregateID, procID))
    }

    func stop() {
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
