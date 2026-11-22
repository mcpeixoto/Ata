@testable import Ata
import XCTest

/// Counts keychain stand-in reads and writes. A class, so the ledger's copy
/// of the store is this same object.
private final class CountingQuotaStore: QuotaStore {
    var gets = 0
    var sets = 0
    var values: [String: String] = [:]

    func get(_ account: String) -> String? {
        gets += 1
        return values[account]
    }

    func set(_ value: String, for account: String) {
        sets += 1
        values[account] = value
    }
}

/// The month line is read from the store once. `record` updates the cache, and
/// a second write for the same meeting does not replace the first.
final class QuotaLedgerCacheTests: XCTestCase {
    private var fake: CountingQuotaStore!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        fake = CountingQuotaStore()
        QuotaLedger.store = fake
        QuotaLedger.resetCache()
    }

    override func tearDown() {
        QuotaLedger.store = KeychainQuotaStore()
        QuotaLedger.resetCache()
        fake = nil
        super.tearDown()
    }

    func testTheMonthIsReadOnceAndTheFirstWriteWins() {
        XCTAssertTrue(QuotaLedger.entries(now: now).isEmpty)
        XCTAssertTrue(QuotaLedger.entries(now: now).isEmpty)
        XCTAssertEqual(fake.gets, 1)

        QuotaLedger.record("meet", seconds: 90, now: now)
        let after = QuotaLedger.entries(now: now)
        XCTAssertEqual(after["meet"]?.seconds ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(fake.gets, 1, "record updates the cache, so the next entries() does not read")
        XCTAssertEqual(fake.sets, 1)

        QuotaLedger.record("meet", seconds: 10, now: now)
        let kept = QuotaLedger.entries(now: now)
        XCTAssertEqual(kept["meet"]?.seconds ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(fake.sets, 1, "first write wins")
        XCTAssertEqual(fake.gets, 1)

        let account = FreeQuota.account(for: now)
        XCTAssertEqual(FreeQuota.decode(fake.values[account])["meet"]?.seconds ?? -1, 90, accuracy: 0.001)
    }
}
