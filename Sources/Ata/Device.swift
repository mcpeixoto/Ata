import Foundation
#if os(macOS)
import SystemConfiguration
#elseif canImport(UIKit)
import UIKit
#endif

/// A device that records or transcribes meetings, as written into meeting.json.
/// With the meetings folder shared between a Mac and an iPhone, it says which
/// one made a meeting and which one is transcribing it.
struct DeviceRef: Codable, Equatable {
    var id: String
    var name: String
}

/// This device. Shared code, so no AppKit here: it compiles for iOS too.
enum Device {
    /// Where the random id is kept. It never leaves the device except inside
    /// meeting.json, and says nothing about the hardware.
    static let idKey = "deviceID"

    static var current: DeviceRef { DeviceRef(id: id, name: name) }

    /// Made once and kept. A random id rather than a hardware one: it only has
    /// to tell this device's meetings from another's.
    static let id: String = {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: idKey), !saved.isEmpty { return saved }
        let made = UUID().uuidString
        d.set(made, forKey: idKey)
        return made
    }()

    /// What the person calls this device, for "recorded on …".
    static let name: String = {
        #if os(macOS)
        // The computer name from Sharing settings. Host.current() can stall on
        // a network lookup, so it is only the fallback.
        if let cf = SCDynamicStoreCopyComputerName(nil, nil) {
            let name = cf as String
            if !name.isEmpty { return name }
        }
        return Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        if Thread.isMainThread { return MainActor.assumeIsolated { UIDevice.current.name } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { UIDevice.current.name } }
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }()

    /// Where a recording is written while it happens: on this device only,
    /// never in a synced folder, so another device never sees a half-written
    /// WAV. The folder moves into the meetings folder when the recording stops.
    /// Created when the first recording needs it, not when it's asked about.
    static var stagingDir: URL {
        Paths.supportDir.appendingPathComponent("Recording", isDirectory: true)
    }
}
