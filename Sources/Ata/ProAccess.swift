import Combine
import Foundation

/// What an Ata Pro subscription unlocks, beyond the free minutes. Free features
/// stay free; these are the ones a lock is allowed to cover.
enum ProFeature: String, CaseIterable {
    case askMeetings
    case customTemplates
    case documentExport
}

/// A paid plan. Monthly and yearly are the App Store subscription; lifetime is
/// the Mac licence. The iPhone never offers the licence (App Review 3.1.1).
enum Plan: String, CaseIterable {
    case monthly
    case yearly
    case lifetime
}

/// Whether this device is Pro, from whichever source has said so. The iPhone
/// pushes StoreKit in; the Mac reads the phone's mirror (and, later, a licence).
/// A nudge, not a lock: the Mac app is open source.
@MainActor
final class ProAccess: ObservableObject {
    static let shared = ProAccess()

    enum Source: Hashable {
        case storeKit
        case iCloudMirror
    }

    @Published private(set) var isPro = false
    @Published private(set) var sources: Set<Source> = []
    /// When the StoreKit entitlement ends, if it has an end. Nil while the
    /// cached "Pro" flag is all we know, and when it is not Pro.
    @Published private(set) var storeKitExpires: Date?

    func setStoreKit(active: Bool, expires: Date?) {
        if active {
            sources.insert(.storeKit)
            storeKitExpires = expires
        } else {
            sources.remove(.storeKit)
            storeKitExpires = nil
        }
        isPro = !sources.isEmpty
        #if os(iOS)
        // A launch that only has the cached flag calls this with no date. `0`
        // on the mirror means "not Pro", so that call must not publish it; the
        // refresh that knows the real expiration writes the mirror.
        guard !Snapshots.rendering, !active || expires != nil else { return }
        ProMirror.write(proUntil: active ? expires : nil)
        #endif
    }

    func setMirror(active: Bool) {
        if active {
            sources.insert(.iCloudMirror)
        } else {
            sources.remove(.iCloudMirror)
        }
        isPro = !sources.isEmpty
    }
}

/// The iPhone writes `proUntil` (epoch seconds, or `0` when not Pro) into the
/// iCloud key-value store. The Mac only reads it, and treats Pro as still on
/// for three days after that instant: the phone rewrites the key only when it
/// is opened. An ad-hoc Mac build has no ubiquity entitlement; the store then
/// reads as 0 and this stays off, and it does not crash.
enum ProMirror {
    static let key = "proUntil"
    /// Three days, in seconds. The grace is `now < proUntil + grace`.
    static let grace: TimeInterval = 3 * 24 * 60 * 60

    /// What `read` sees. The app reads iCloud; tests hand back a fixed epoch.
    static var epoch: () -> Double = {
        NSUbiquitousKeyValueStore.default.double(forKey: key)
    }

    /// iPhone only. The Mac never writes this key.
    static func write(proUntil: Date?) {
        #if os(iOS)
        let store = NSUbiquitousKeyValueStore.default
        store.set(proUntil?.timeIntervalSince1970 ?? 0, forKey: key)
        store.synchronize()
        #endif
    }

    /// The entitlement's expiration, or nil when the stored value is missing,
    /// `0` (not Pro) or negative.
    static func read() -> Date? {
        let value = epoch()
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    static func isActive(now: Date = Date()) -> Bool {
        guard let until = read() else { return false }
        return now < until.addingTimeInterval(grace)
    }
}
