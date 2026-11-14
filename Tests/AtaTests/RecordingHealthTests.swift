@testable import Ata
import XCTest

/// Disk room, a stalled microphone, and how long the Live Activity may count
/// without the app. Pure: no session, no files.
final class RecordingHealthTests: XCTestCase {
    func testUnknownFreeSpaceDoesNotRefuse() {
        XCTAssertTrue(RecordingHealth.hasRoom(available: nil))
        XCTAssertFalse(RecordingHealth.hasRoom(available: RecordingHealth.minimumFreeBytes - 1))
        XCTAssertTrue(RecordingHealth.hasRoom(available: RecordingHealth.minimumFreeBytes))
        XCTAssertEqual(RecordingHealth.minimumFreeBytes, 200_000_000)
    }

    func testAStallRestartsOnceAndThenWaitsOutTheBackoff() {
        XCTAssertFalse(RecordingHealth.shouldRestartCapture(capturing: false, secondsSinceBuffer: 30,
                                                            secondsSinceRestart: 30))
        XCTAssertFalse(RecordingHealth.shouldRestartCapture(capturing: true, secondsSinceBuffer: 4,
                                                            secondsSinceRestart: 30), "four seconds is not yet a stall")
        XCTAssertTrue(RecordingHealth.shouldRestartCapture(capturing: true, secondsSinceBuffer: 4.1,
                                                           secondsSinceRestart: 30))
        XCTAssertFalse(RecordingHealth.shouldRestartCapture(capturing: true, secondsSinceBuffer: 10,
                                                            secondsSinceRestart: 4.9), "not faster than the retry backoff")
        XCTAssertTrue(RecordingHealth.shouldRestartCapture(capturing: true, secondsSinceBuffer: 10,
                                                           secondsSinceRestart: RecordingHealth.stallRetryAfter))
    }

    func testAStallWarnsBeforeItRestarts() {
        XCTAssertEqual(RecordingHealth.stallRecoveryOrder, [.warn, .restart])
    }

    func testTheLiveActivityIsRefreshedInsideItsStaleWindow() {
        XCTAssertFalse(RecordingHealth.shouldRefreshActivity(secondsSinceRefresh: 59))
        XCTAssertTrue(RecordingHealth.shouldRefreshActivity(secondsSinceRefresh: 60))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RecordingHealth.activityStaleDate(now: now).timeIntervalSince(now), 120)
        XCTAssertLessThanOrEqual(RecordingHealth.activityRefreshAfter * 2, RecordingHealth.activityStaleAfter)
    }

    func testASystemStartErrorBecomesOneSentence() {
        XCTAssertEqual(RecordingStartMessage.text(knownDescription: "No active microphone was found."),
                       "No active microphone was found.")
        let fallback = RecordingStartMessage.text(knownDescription: nil)
        XCTAssertTrue(fallback.contains("could not start recording"), fallback)
        XCTAssertFalse(fallback.contains("NSError"), "the raw system error stays in the log")
    }
}
