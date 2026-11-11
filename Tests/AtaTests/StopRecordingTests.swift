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

/// Stopping goes back to idle at once; filing the meeting runs here, one stop
/// after another, and the next recording waits for it.
final class FinisherTests: XCTestCase {
    @MainActor
    func testJobsRunInOrderEvenWhenTheFirstIsSlow() async {
        let finisher = Finisher()
        var order: [Int] = []
        finisher.run {
            try? await Task.sleep(nanoseconds: 200_000_000)
            order.append(1)
        }
        finisher.run { order.append(2) }
        XCTAssertEqual(finisher.pending, 2)
        await finisher.wait()
        XCTAssertEqual(order, [1, 2])
        XCTAssertEqual(finisher.pending, 0)
    }

    @MainActor
    func testRunReturnsBeforeTheJobIsDone() {
        let finisher = Finisher()
        var done = false
        finisher.run {
            try? await Task.sleep(nanoseconds: 100_000_000)
            done = true
        }
        XCTAssertFalse(done)
    }

    @MainActor
    func testWaitingWithNothingGivenReturnsAtOnce() async {
        let finisher = Finisher()
        await finisher.wait()
        XCTAssertEqual(finisher.pending, 0)
    }
}
