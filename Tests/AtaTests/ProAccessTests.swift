@testable import Ata
import XCTest

/// One entitlement, from StoreKit or the iCloud mirror. The Mac stays Pro for
/// three days after the phone's `proUntil`, and `0` is not a date.
@MainActor
final class ProAccessTests: XCTestCase {
    private var savedEpoch: (() -> Double)?

    override func setUp() {
        savedEpoch = ProMirror.epoch
    }

    override func tearDown() {
        if let savedEpoch { ProMirror.epoch = savedEpoch }
    }

    /// A `<=` comparison, or a grace other than three days, unlocks or locks the wrong day.
    func testGraceIsThreeDaysAndEndsOnTheBoundary() {
        let until = Date(timeIntervalSince1970: 1_700_000_000)
        // 1_700_000_000 + 3 * 24 * 60 * 60
        let boundary = Date(timeIntervalSince1970: 1_700_259_200)
        ProMirror.epoch = { until.timeIntervalSince1970 }

        XCTAssertTrue(ProMirror.isActive(now: until))
        XCTAssertTrue(ProMirror.isActive(now: boundary.addingTimeInterval(-1)))
        XCTAssertFalse(ProMirror.isActive(now: boundary))
        XCTAssertFalse(ProMirror.isActive(now: boundary.addingTimeInterval(1)))
        XCTAssertEqual(ProMirror.read(), until)
    }

    /// The phone writes 0 when the subscription is gone. Missing is the same.
    func testZeroEpochIsNotPro() {
        ProMirror.epoch = { 0 }
        XCTAssertNil(ProMirror.read())
        XCTAssertFalse(ProMirror.isActive(now: Date(timeIntervalSince1970: 1_700_000_000)))

        ProMirror.epoch = { -1 }
        XCTAssertNil(ProMirror.read())
        XCTAssertFalse(ProMirror.isActive(now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    /// Either source is enough. Dropping one leaves Pro on while the other remains.
    func testAnySourceMeansPro() {
        let access = ProAccess()
        XCTAssertFalse(access.isPro)
        XCTAssertTrue(access.sources.isEmpty)

        access.setStoreKit(active: true, expires: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(access.sources, [.storeKit])

        access.setMirror(active: true)
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(access.sources, [.storeKit, .iCloudMirror])

        access.setStoreKit(active: false, expires: nil)
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(access.sources, [.iCloudMirror])

        access.setMirror(active: false)
        XCTAssertFalse(access.isPro)
        XCTAssertTrue(access.sources.isEmpty)
    }

    /// A licence is a third source. The Mac also re-reads the mirror when iCloud says it changed.
    func testALicenceUnlocksAndTheMirrorUpdatesWheniCloudChanges() {
        let access = ProAccess()
        access.setLicence(active: true)
        XCTAssertTrue(access.isPro)
        XCTAssertEqual(access.sources, [.licence])
        access.setLicence(active: false)
        XCTAssertFalse(access.isPro)

        ProMirror.epoch = { 0 }
        access.start()
        XCTAssertFalse(access.sources.contains(.iCloudMirror))

        ProMirror.epoch = { 1_800_000_000 }
        NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                        object: NSUbiquitousKeyValueStore.default)
        XCTAssertTrue(access.isPro)
        XCTAssertTrue(access.sources.contains(.iCloudMirror))

        ProMirror.epoch = { 0 }
        NotificationCenter.default.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                        object: NSUbiquitousKeyValueStore.default)
        XCTAssertFalse(access.isPro)
    }
}
