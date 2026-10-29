@testable import Ata
import XCTest

/// The iPhone's five free meetings a month: what counts, in which month, and
/// that a deleted meeting stays counted. Pure: no keychain, no files.
final class FreeQuotaTests: XCTestCase {
    private let phone = DeviceRef(id: "the-phone", name: "iPhone", kind: DeviceRef.iPhone)
    private let mac = DeviceRef(id: "the-mac", name: "Mac", kind: DeviceRef.mac)

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func meeting(_ id: String, at date: Date, origin: DeviceRef?) -> Meeting {
        var m = Meeting(id: id, startedAt: date, endedAt: nil, duration: nil, app: nil, status: .done, error: nil)
        m.origin = origin
        return m
    }

    func testMeetingsFromTheMacAreNotCounted() {
        let now = date(2026, 10, 20)
        let meetings = [
            meeting("a", at: date(2026, 10, 2), origin: phone),
            meeting("b", at: date(2026, 10, 3), origin: mac),
            meeting("c", at: date(2026, 10, 4), origin: mac),
            meeting("d", at: date(2026, 10, 5), origin: nil),
        ]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [], now: now, calendar: calendar), 1)
    }

    func testOnlyTheCurrentMonthCounts() {
        let meetings = [
            meeting("sep-last-minute", at: date(2026, 9, 30, 23, 59), origin: phone),
            meeting("oct-first-minute", at: date(2026, 10, 1, 0, 0), origin: phone),
            meeting("oct-last-minute", at: date(2026, 10, 31, 23, 59), origin: phone),
            meeting("nov", at: date(2026, 11, 1, 0, 0), origin: phone),
        ]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [], now: date(2026, 10, 15), calendar: calendar), 2)
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [], now: date(2026, 11, 1, 0, 1), calendar: calendar), 1)
        XCTAssertEqual(FreeQuota.account(for: date(2026, 10, 31, 23, 59), calendar: calendar), "quota-2026-10")
        XCTAssertEqual(FreeQuota.account(for: date(2026, 11, 1, 0, 0), calendar: calendar), "quota-2026-11")
    }

    func testLedgerAndLibraryAreNotCountedTwice() {
        let now = date(2026, 10, 20)
        let meetings = [
            meeting("a", at: date(2026, 10, 2), origin: phone),
            meeting("b", at: date(2026, 10, 3), origin: phone),
        ]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: ["a", "b"], now: now, calendar: calendar), 2)
        // An import of last year's file is dated last year, and the ledger counts it.
        let old = meeting("old-file", at: date(2025, 3, 1), origin: phone)
        XCTAssertEqual(FreeQuota.used(meetings: meetings + [old], ledger: ["a", "b", "old-file"],
                                      now: now, calendar: calendar), 3)
    }

    func testDeletedMeetingStillCountsThroughTheLedger() {
        let now = date(2026, 10, 20)
        let ledger: Set<String> = ["gone-1", "gone-2", "kept"]
        let meetings = [meeting("kept", at: date(2026, 10, 9), origin: phone)]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: ledger, now: now, calendar: calendar), 3)
        XCTAssertEqual(FreeQuota.used(meetings: [], ledger: ledger, now: now, calendar: calendar), 3)
        XCTAssertEqual(FreeQuota.remaining(used: 3), 2)
        XCTAssertEqual(FreeQuota.remaining(used: 9), 0)
    }

    func testLedgerRoundTripsIdsWithCommas() {
        let ids: Set<String> = ["2026-10-01 10.00.00 Call, Bob", "2026-10-02 11.00.00 In person"]
        XCTAssertEqual(FreeQuota.decode(FreeQuota.encode(ids)), ids)
        XCTAssertEqual(FreeQuota.decode(nil), [])
        XCTAssertEqual(FreeQuota.decode(""), [])
    }

    func testDeviceRefWithoutKindDecodes() throws {
        let json = Data(#"{"id":"old-phone","name":"iPhone"}"#.utf8)
        let ref = try JSONDecoder().decode(DeviceRef.self, from: json)
        XCTAssertEqual(ref, DeviceRef(id: "old-phone", name: "iPhone"))
        XCTAssertNil(ref.kind)
        let encoded = try JSONEncoder().encode(phone)
        XCTAssertEqual(try JSONDecoder().decode(DeviceRef.self, from: encoded).kind, DeviceRef.iPhone)
    }

    func testThisIPhonesMeetingsWithoutKindCount() {
        let now = date(2026, 10, 20)
        let older = DeviceRef(id: "the-phone", name: "iPhone")
        let meetings = [meeting("a", at: date(2026, 10, 2), origin: older),
                        meeting("b", at: date(2026, 10, 2), origin: DeviceRef(id: "someone-else", name: "Mac"))]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [], now: now, calendar: calendar,
                                      deviceID: "the-phone"), 1)
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [], now: now, calendar: calendar), 0)
    }

    func testPlaceholdersAreNotCounted() {
        var m = meeting("still-in-icloud", at: date(2026, 10, 2), origin: phone)
        m.cloudPlaceholder = true
        XCTAssertEqual(FreeQuota.used(meetings: [m], ledger: [], now: date(2026, 10, 20), calendar: calendar), 0)
    }

    func testTheMacIsAMac() {
        #if os(macOS)
        XCTAssertEqual(Device.current.kind, DeviceRef.mac)
        #endif
    }
}
