@testable import Ata
import XCTest

/// Stopping a recording must come back even when Core Audio doesn't: the
/// teardown runs off the main actor and is waited for only so long.
final class StopRecordingTests: XCTestCase {
    func testQuickWorkFinishesInTime() async {
        let finished = await BoundedWait.run(seconds: 5) {}
        XCTAssertTrue(finished)
    }

    func testStuckWorkIsNotWaitedForPastTheLimit() async {
        let started = Date()
        let finished = await BoundedWait.run(seconds: 0.2) { Thread.sleep(forTimeInterval: 3) }
        XCTAssertFalse(finished)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testWorkDoesNotRunOnTheMainThread() async {
        let onMain = Box()
        _ = await BoundedWait.run(seconds: 5) { onMain.value = Thread.isMainThread }
        XCTAssertEqual(onMain.value, false)
    }

    func testTheLimitIsShort() {
        XCTAssertLessThanOrEqual(Recorder.teardownLimit, 10)
    }

    private final class Box: @unchecked Sendable {
        var value: Bool?
    }
}
