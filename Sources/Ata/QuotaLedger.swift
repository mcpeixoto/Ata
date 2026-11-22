import Foundation

/// The seconds of audio this device made each month, kept in the keychain so
/// that deleting a meeting or reinstalling Ata does not hand the free minutes
/// back; see `FreeQuota`. The iPhone and the Mac each have their own keychain,
/// so each has its own 300 minutes. Imports may record here off the main
/// thread, so reads and writes are serialised.
enum QuotaLedger {
    private static let lock = NSLock()

    static func entries(now: Date = Date()) -> [String: FreeQuota.Entry] {
        lock.lock(); defer { lock.unlock() }
        return FreeQuota.decode(Keychain.get(FreeQuota.account(for: now)))
    }

    /// First write wins. A later call for the same meeting does not add its
    /// seconds again.
    static func record(_ meetingID: String, seconds: Double, now: Date = Date()) {
        guard !Snapshots.rendering else { return }
        guard seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let account = FreeQuota.account(for: now)
        var stored = FreeQuota.decode(Keychain.get(account))
        guard stored[meetingID] == nil else { return }
        stored[meetingID] = FreeQuota.Entry(seconds: seconds)
        Keychain.set(FreeQuota.encode(stored), for: account)
    }
}
