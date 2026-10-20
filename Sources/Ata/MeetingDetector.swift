import AppKit
import CoreAudio

/// Detects meetings in any app: when another process starts using the microphone
/// (Slack, Zoom, Teams, Meet in the browser, FaceTime, …), that counts as a meeting.
/// Uses Core Audio's list of audio processes (macOS 14+).
@MainActor
final class MeetingDetector {
    /// Name of the app using the microphone, or nil.
    private(set) var activeApp: String?
    var onStart: ((String) -> Void)?
    var onEnd: (() -> Void)?

    private var timer: Timer?
    private var seenCount = 0
    private var goneCount = 0
    private var candidate: String?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        activeApp = nil; candidate = nil; seenCount = 0; goneCount = 0
    }

    private func poll() {
        let app = CoreAudioProbe.meetingAppUsingMic()
        if let app {
            goneCount = 0
            if activeApp == nil {
                seenCount = (candidate == app) ? seenCount + 1 : 1
                candidate = app
                if seenCount >= 2 { // ~4 s in a row
                    activeApp = app
                    onStart?(app)
                }
            }
        } else {
            seenCount = 0; candidate = nil
            if activeApp != nil {
                goneCount += 1
                if goneCount >= 8 { // ~16 s with nobody on the mic
                    activeApp = nil
                    goneCount = 0
                    onEnd?()
                }
            }
        }
    }
}

enum CoreAudioProbe {
    /// Processes other than Ata that are capturing from the microphone right now.
    static func meetingAppUsingMic() -> String? {
        let myPID = ProcessInfo.processInfo.processIdentifier
        for id in processObjects() {
            guard (get(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0 else { continue }
            let pid = get(id, kAudioProcessPropertyPID, pid_t(-1)) ?? -1
            guard pid != myPID else { continue }
            let bundle = string(id, kAudioProcessPropertyBundleID) ?? ""
            if isIgnored(bundle) { continue }
            return displayName(bundle: bundle, pid: pid)
        }
        return nil
    }

    private static func isIgnored(_ bundle: String) -> Bool {
        if bundle.isEmpty { return false }
        if bundle.hasPrefix("ai.interactive.ata") { return true }
        // Apple processes that use the mic without being meetings (Siri, dictation, …). FaceTime counts.
        if bundle.hasPrefix("com.apple.") {
            return !(bundle.hasPrefix("com.apple.FaceTime") || bundle.hasPrefix("com.apple.Safari")
                     || bundle.hasPrefix("com.apple.WebKit"))
        }
        return false
    }

    private static let known: [(String, String)] = [
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("us.zoom", "Zoom"),
        ("com.microsoft.teams", "Teams"),
        ("com.google.Chrome", "Chrome"),
        ("com.brave.Browser", "Brave"),
        ("company.thebrowser", "Arc"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("com.cisco.webexmeetings", "Webex"),
        ("com.cisco.webex", "Webex"),
        ("net.whatsapp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("com.skype", "Skype"),
        ("com.around", "Around"),
        ("so.tuple", "Tuple"),
    ]

    static func displayName(bundle: String, pid: pid_t) -> String {
        let lower = bundle.lowercased()
        if let match = known.first(where: { lower.hasPrefix($0.0.lowercased()) }) { return match.1 }
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name.replacingOccurrences(of: " Helper", with: "")
        }
        return bundle.isEmpty ? "Meeting" : (bundle.split(separator: ".").last.map(String.init) ?? "Meeting")
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let err = ids.withUnsafeMutableBytes { buf in
            AudioObjectGetPropertyData(system, &addr, 0, nil, &size, buf.baseAddress!)
        }
        return err == noErr ? ids : []
    }

    private static func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        return err == noErr ? value : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
