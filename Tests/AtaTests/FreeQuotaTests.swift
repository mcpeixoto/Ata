@testable import Ata
import XCTest

/// The iPhone's 300 free minutes a month: what counts, in which month, and
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

    private func meeting(_ id: String, at date: Date, origin: DeviceRef?, seconds: Double? = 60) -> Meeting {
        var m = Meeting(id: id, startedAt: date, endedAt: nil, duration: seconds, app: nil, status: .done, error: nil)
        m.origin = origin
        return m
    }

    private func ledger(_ pairs: [(String, Double?)]) -> [String: FreeQuota.Entry] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, FreeQuota.Entry(seconds: $0.1)) })
    }

    func testTheAllowanceIsThreeHundredMinutes() {
        XCTAssertEqual(FreeQuota.limitMinutes, 300)
        XCTAssertEqual(FreeQuota.remaining(used: 0), 300)
        XCTAssertEqual(FreeQuota.remaining(used: 299), 1)
        XCTAssertEqual(FreeQuota.remaining(used: 300), 0)
        XCTAssertEqual(FreeQuota.remaining(used: 301), 0)
    }

    func testMinutesRoundUpOnTheTotal() {
        XCTAssertEqual(FreeQuota.minutes(fromSeconds: 0), 0)
        XCTAssertEqual(FreeQuota.minutes(fromSeconds: 1), 1)
        XCTAssertEqual(FreeQuota.minutes(fromSeconds: 60), 1)
        XCTAssertEqual(FreeQuota.minutes(fromSeconds: 61), 2)
        // Two short meetings share one rounding, so 30s + 20s is one minute.
        XCTAssertEqual(FreeQuota.minutes(fromSeconds: 50), 1)
        XCTAssertEqual(FreeQuota.minutes(fromSeconds: 300 * 60), 300)
    }

    func testMeetingsFromTheMacAreNotCounted() {
        let now = date(2026, 10, 20)
        let meetings = [
            meeting("a", at: date(2026, 10, 2), origin: phone, seconds: 90),
            meeting("b", at: date(2026, 10, 3), origin: mac, seconds: 3600),
            meeting("c", at: date(2026, 10, 4), origin: mac, seconds: 3600),
            meeting("d", at: date(2026, 10, 5), origin: nil, seconds: 3600),
        ]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [:], now: now, calendar: calendar, kind: DeviceRef.iPhone), 2)
    }

    func testOnlyTheCurrentMonthCounts() {
        let meetings = [
            meeting("sep-last-minute", at: date(2026, 9, 30, 23, 59), origin: phone, seconds: 60),
            meeting("oct-first-minute", at: date(2026, 10, 1, 0, 0), origin: phone, seconds: 60),
            meeting("oct-last-minute", at: date(2026, 10, 31, 23, 59), origin: phone, seconds: 120),
            meeting("nov", at: date(2026, 11, 1, 0, 0), origin: phone, seconds: 60),
        ]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [:], now: date(2026, 10, 15), calendar: calendar, kind: DeviceRef.iPhone), 3)
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [:], now: date(2026, 11, 1, 0, 1), calendar: calendar, kind: DeviceRef.iPhone), 1)
        XCTAssertEqual(FreeQuota.account(for: date(2026, 10, 31, 23, 59), calendar: calendar), "quota-2026-10")
        XCTAssertEqual(FreeQuota.account(for: date(2026, 11, 1, 0, 0), calendar: calendar), "quota-2026-11")
    }

    func testLedgerAndLibraryAreNotCountedTwice() {
        let now = date(2026, 10, 20)
        let meetings = [
            meeting("a", at: date(2026, 10, 2), origin: phone, seconds: 60),
            meeting("b", at: date(2026, 10, 3), origin: phone, seconds: 120),
        ]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: ledger([("a", 60), ("b", 120)]),
                                      now: now, calendar: calendar, kind: DeviceRef.iPhone), 3)
        // An import of last year's file is dated last year, and the ledger counts it.
        let old = meeting("old-file", at: date(2025, 3, 1), origin: phone, seconds: 600)
        XCTAssertEqual(FreeQuota.used(meetings: meetings + [old],
                                      ledger: ledger([("a", 60), ("b", 120), ("old-file", 600)]),
                                      now: now, calendar: calendar, kind: DeviceRef.iPhone), 13)
    }

    func testDeletedMeetingStillCountsThroughTheLedger() {
        let now = date(2026, 10, 20)
        let stored = ledger([("gone-1", 60), ("gone-2", 90), ("kept", 30)])
        let meetings = [meeting("kept", at: date(2026, 10, 9), origin: phone, seconds: 30)]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: stored, now: now, calendar: calendar, kind: DeviceRef.iPhone), 3)
        XCTAssertEqual(FreeQuota.used(meetings: [], ledger: stored, now: now, calendar: calendar, kind: DeviceRef.iPhone), 3)
    }

    func testALegacyLineUsesTheLibraryDurationOrZero() {
        let now = date(2026, 10, 20)
        let stored = ledger([("still-here", nil), ("deleted", nil)])
        let meetings = [meeting("still-here", at: date(2026, 10, 2), origin: phone, seconds: 90)]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: stored, now: now, calendar: calendar, kind: DeviceRef.iPhone), 2)
        XCTAssertEqual(FreeQuota.used(meetings: [], ledger: stored, now: now, calendar: calendar, kind: DeviceRef.iPhone), 0)
    }

    func testAShortRecordingCountsAndOneStillGoingDoesNot() {
        let now = date(2026, 10, 20)
        let tap = meeting("tap", at: date(2026, 10, 2), origin: phone, seconds: 12)
        let almost = meeting("almost", at: date(2026, 10, 3), origin: phone, seconds: 29.9)
        let going = meeting("going", at: date(2026, 10, 4), origin: phone, seconds: nil)
        let real = meeting("real", at: date(2026, 10, 5), origin: phone, seconds: 60)
        XCTAssertNil(going.duration, "still recording")
        // 12 + 29.9 + 60 = 101.9 seconds, rounded up once: 2 minutes. The one still
        // recording has no duration and uses none of the allowance.
        XCTAssertEqual(FreeQuota.used(meetings: [tap, almost, going, real], ledger: [:],
                                      now: now, calendar: calendar, kind: DeviceRef.iPhone), 2)
        XCTAssertTrue(FreeQuota.countsWhenStopped(duration: 12, hasAudio: true))
        XCTAssertTrue(FreeQuota.countsWhenStopped(duration: 29.9, hasAudio: true))
        XCTAssertFalse(FreeQuota.countsWhenStopped(duration: 0, hasAudio: true))
        XCTAssertFalse(FreeQuota.countsWhenStopped(duration: 60, hasAudio: false), "no audio, nothing to count")
        XCTAssertFalse(FreeQuota.countsWhenStopped(duration: nil, hasAudio: true))
    }

    func testLedgerRoundTripsIdsWithCommasAndSeconds() {
        let entries = ledger([
            ("2026-10-01 10.00.00 Call, Bob", 90.5),
            ("2026-10-02 11.00.00 In person", 3600),
            ("legacy-id", nil),
        ])
        XCTAssertEqual(FreeQuota.decode(FreeQuota.encode(entries)), entries)
        XCTAssertEqual(FreeQuota.decode(nil), [:])
        XCTAssertEqual(FreeQuota.decode(""), [:])
        let legacy = FreeQuota.decode("still-here\ndeleted")
        XCTAssertEqual(legacy["still-here"], FreeQuota.Entry(seconds: nil))
        XCTAssertEqual(legacy["deleted"], FreeQuota.Entry(seconds: nil))
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
        let meetings = [meeting("a", at: date(2026, 10, 2), origin: older, seconds: 60),
                        meeting("b", at: date(2026, 10, 2), origin: DeviceRef(id: "someone-else", name: "Mac"), seconds: 60)]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [:], now: now, calendar: calendar,
                                      deviceID: "the-phone", kind: DeviceRef.iPhone), 1)
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [:], now: now, calendar: calendar, kind: DeviceRef.iPhone), 0)
    }

    func testPlaceholdersAreNotCounted() {
        var m = meeting("still-in-icloud", at: date(2026, 10, 2), origin: phone, seconds: 600)
        m.cloudPlaceholder = true
        XCTAssertEqual(FreeQuota.used(meetings: [m], ledger: [:], now: date(2026, 10, 20), calendar: calendar, kind: DeviceRef.iPhone), 0)
    }

    func testEachDeviceCountsOnlyItsOwnMeetings() {
        let now = date(2026, 10, 20)
        let meetings = [
            meeting("phone", at: date(2026, 10, 2), origin: phone, seconds: 60),
            meeting("computer", at: date(2026, 10, 3), origin: mac, seconds: 120),
        ]
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [:], now: now, calendar: calendar,
                                      kind: DeviceRef.iPhone), 1)
        XCTAssertEqual(FreeQuota.used(meetings: meetings, ledger: [:], now: now, calendar: calendar,
                                      kind: DeviceRef.mac), 2)
    }

    func testTheMacIsAMac() {
        #if os(macOS)
        XCTAssertEqual(Device.current.kind, DeviceRef.mac)
        #endif
    }

    func testTheMacLimitIsOffUntilProCanBeUnlocked() {
        XCTAssertTrue(FreeQuota.appliesOnMac)
    }
}
