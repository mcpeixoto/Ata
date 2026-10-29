import Foundation

/// The meetings this iPhone made each month, kept in the keychain so that
/// deleting them or reinstalling Ata does not hand the free ones back; see
/// `FreeQuota`. Imports from the Watch record here off the main thread, so
/// reads and writes are serialised.
enum QuotaLedger {
    private static let lock = NSLock()

    static func ids(now: Date = Date()) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return FreeQuota.decode(Keychain.get(FreeQuota.account(for: now)))
    }

    static func record(_ meetingID: String, now: Date = Date()) {
        guard !Snapshots.rendering else { return }
        lock.lock(); defer { lock.unlock() }
        let account = FreeQuota.account(for: now)
        var ids = FreeQuota.decode(Keychain.get(account))
        guard ids.insert(meetingID).inserted else { return }
        Keychain.set(FreeQuota.encode(ids), for: account)
    }
}
