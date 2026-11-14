import XCTest

// PhoneDecisions.swift and WidgetRecordingFace.swift are compiled into this
// bundle, so the decisions are tested without launching Ata.
final class PhoneDecisionsTests: XCTestCase {
    func testShowTheReasonOnlyWhenAtaIsOrIsBecomingForeground() {
        XCTAssertEqual(BlockedStart.presentation(appIsActive: true, becomingForeground: false), .showNow)
        XCTAssertEqual(BlockedStart.presentation(appIsActive: false, becomingForeground: true), .showNow)
        XCTAssertEqual(BlockedStart.presentation(appIsActive: true, becomingForeground: true), .showNow)
        XCTAssertEqual(BlockedStart.presentation(appIsActive: false, becomingForeground: false), .doNotArm)
    }

    func testStartAtTheFreeLimitThrowsAndRecordsNothing() {
        var recorded = false
        XCTAssertThrowsError(try RecordingStart.begin(needsPro: true, record: { recorded = true })) { error in
            XCTAssertEqual(error as? FreeQuotaError, .limitReached)
        }
        XCTAssertFalse(recorded)

        recorded = false
        XCTAssertNoThrow(try RecordingStart.begin(needsPro: false, record: { recorded = true }))
        XCTAssertTrue(recorded)
    }

    func testStartingARecordingPausesTheQueueTheWayIOSExpiryDoes() {
        let started = RecordingQueue.decide(.recordingWillStart, jobRunning: true)
        let expired = RecordingQueue.decide(.backgroundExpired, jobRunning: true)
        XCTAssertEqual(started, expired)
        XCTAssertTrue(started.queuePaused)
        XCTAssertTrue(started.cancelJob)
        XCTAssertTrue(started.savesMeetingAsPending)

        let idle = RecordingQueue.decide(.recordingWillStart, jobRunning: false)
        XCTAssertTrue(idle.queuePaused)
        XCTAssertFalse(idle.cancelJob)
        XCTAssertFalse(idle.savesMeetingAsPending)
    }

    func testStoppingARecordingResumesTheQueue() {
        let stopped = RecordingQueue.decide(.recordingStopped, jobRunning: true)
        XCTAssertFalse(stopped.queuePaused)
        XCTAssertFalse(stopped.cancelJob)
        XCTAssertFalse(stopped.savesMeetingAsPending)
    }
}

final class WidgetRecordingFaceTests: XCTestCase {
    func testTheWidgetFreezesWhilePausedAndContinuesAfterResume() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let running = WidgetRecordingFace.face(isRecording: true, isPaused: false, recordedSeconds: 90, now: now)
        XCTAssertEqual(running.recordingSince, now.addingTimeInterval(-90))
        XCTAssertNil(running.pausedSeconds)
        XCTAssertTrue(running.isRecording)

        // Thirty seconds of pause must not move the clock.
        let paused = WidgetRecordingFace.face(isRecording: true, isPaused: true, recordedSeconds: 90,
                                              now: now.addingTimeInterval(30))
        XCTAssertNil(paused.recordingSince)
        XCTAssertEqual(paused.pausedSeconds, 90)
        XCTAssertEqual(WidgetRecordingFace.clock(paused.pausedSeconds!), "1:30")
        XCTAssertTrue(paused.isRecording)

        let resumedAt = now.addingTimeInterval(30)
        let resumed = WidgetRecordingFace.face(isRecording: true, isPaused: false, recordedSeconds: 90, now: resumedAt)
        XCTAssertEqual(resumed.recordingSince, resumedAt.addingTimeInterval(-90))
        XCTAssertEqual(resumedAt.timeIntervalSince(resumed.recordingSince!), 90, accuracy: 0.001)
        XCTAssertNil(resumed.pausedSeconds)

        let idle = WidgetRecordingFace.face(isRecording: false, isPaused: true, recordedSeconds: 90, now: resumedAt)
        XCTAssertFalse(idle.isRecording)
        XCTAssertNil(idle.recordingSince)
        XCTAssertNil(idle.pausedSeconds)
        XCTAssertEqual(WidgetRecordingFace.clock(3661), "1:01:01")
        XCTAssertEqual(WidgetRecordingFace.clock(0), "0:00")
    }
}
