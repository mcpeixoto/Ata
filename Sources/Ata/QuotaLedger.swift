import Foundation

/// Where a month's quota line is kept. The keychain in the app; a stand-in
/// in tests, so a read can be counted without touching the login keychain.
protocol QuotaStore {
    func get(_ account: String) -> String?
    func set(_ value: String, for account: String)
}

/// The keychain account is the month (`quota-2026-10`), via `Keychain`.
struct KeychainQuotaStore: QuotaStore {
    func get(_ account: String) -> String? { Keychain.get(account) }
    func set(_ value: String, for account: String) { Keychain.set(value, for: account) }
}

/// The seconds of audio this device made each month, kept in the keychain so
/// that deleting a meeting or reinstalling Ata does not hand the free minutes
/// back; see `FreeQuota`. The iPhone and the Mac each have their own keychain,
/// so each has its own 300 minutes. Imports may record here off the main
/// thread, so reads and writes are serialised.
///
/// The keychain is read at most once per month-account per process. `record`
/// updates that cache and writes through. Tests replace `store` and call
/// `resetCache()` so one case does not see another's month.
enum QuotaLedger {
    private static let lock = NSLock()
    /// A month that has been read. `text` is nil when the store had nothing:
    /// a missing key would be read again, and a dictionary of optionals cannot
    /// tell "stored nil" from "not loaded".
    private struct Loaded {
        var text: String?
    }
    private static var cache: [String: Loaded] = [:]
    private static var _store: QuotaStore = KeychainQuotaStore()

    static var store: QuotaStore {
        get {
            lock.lock(); defer { lock.unlock() }
            return _store
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _store = newValue
        }
    }

    /// Drops the in-memory month lines. The store is left as it is.
    static func resetCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    static func entries(now: Date = Date()) -> [String: FreeQuota.Entry] {
        lock.lock(); defer { lock.unlock() }
        return FreeQuota.decode(read(FreeQuota.account(for: now)))
    }

    /// First write wins. A later call for the same meeting does not add its
    /// seconds again.
    static func record(_ meetingID: String, seconds: Double, now: Date = Date()) {
        guard !Snapshots.rendering else { return }
        guard seconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let account = FreeQuota.account(for: now)
        var stored = FreeQuota.decode(read(account))
        guard stored[meetingID] == nil else { return }
        stored[meetingID] = FreeQuota.Entry(seconds: seconds)
        write(FreeQuota.encode(stored), account: account)
    }

    /// Caller holds `lock`.
    private static func read(_ account: String) -> String? {
        if let known = cache[account] { return known.text }
        let value = _store.get(account)
        cache[account] = Loaded(text: value)
        return value
    }

    /// Caller holds `lock`.
    private static func write(_ value: String, account: String) {
        cache[account] = Loaded(text: value)
        _store.set(value, for: account)
    }
}
