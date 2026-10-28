import XCTest

// RecorderState.swift is compiled straight into this bundle, so the state
// machine is tested without an app, a simulator microphone or a host.
final class RecorderStateTests: XCTestCase {
    func testStartBeginsCapture() {
        var s = RecorderState()
        XCTAssertEqual(s.handle(.start), [.beginCapture])
        XCTAssertEqual(s.phase, .recording)
        XCTAssertTrue(s.isCapturing)
        XCTAssertTrue(s.isActive)
    }

    func testStopFinishesCapture() {
        var s = RecorderState()
        _ = s.handle(.start)
        XCTAssertEqual(s.handle(.stop), [.finishCapture])
        XCTAssertEqual(s.phase, .stopped)
        XCTAssertFalse(s.isActive)
    }

    func testCallInterruptsAndResumesIntoTheSameRecording() {
        var s = RecorderState()
        _ = s.handle(.start)
        XCTAssertEqual(s.handle(.interruptionBegan), [.pauseCapture])
        XCTAssertEqual(s.phase, .interrupted)
        XCTAssertFalse(s.isCapturing)
        XCTAssertTrue(s.isActive, "an interrupted recording is still a recording")
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: true)), [.resumeCapture])
        XCTAssertEqual(s.phase, .recording)
        XCTAssertEqual(s.interruptions, 1)
    }

    func testInterruptionThatDoesNotResumeWaitsForYou() {
        var s = RecorderState()
        _ = s.handle(.start)
        _ = s.handle(.interruptionBegan)
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: false)), [])
        XCTAssertEqual(s.phase, .interrupted)
        XCTAssertEqual(s.handle(.resume), [.resumeCapture])
        XCTAssertEqual(s.phase, .recording)
    }

    func testStopWhileInterruptedClosesTheFile() {
        var s = RecorderState()
        _ = s.handle(.start)
        _ = s.handle(.interruptionBegan)
        XCTAssertEqual(s.handle(.stop), [.finishCapture])
        XCTAssertEqual(s.phase, .stopped)
    }

    func testRouteChangeRestartsCaptureOnlyWhileCapturing() {
        var s = RecorderState()
        XCTAssertEqual(s.handle(.routeChanged), [], "nothing to restart before recording")
        _ = s.handle(.start)
        XCTAssertEqual(s.handle(.routeChanged), [.restartCapture])
        XCTAssertEqual(s.phase, .recording)
        _ = s.handle(.interruptionBegan)
        XCTAssertEqual(s.handle(.routeChanged), [], "an interrupted recording restarts when it resumes")
    }

    func testMediaServicesResetRebuildsWhileRecording() {
        var s = RecorderState()
        _ = s.handle(.start)
        XCTAssertEqual(s.handle(.mediaServicesReset), [.rebuildSession])
        XCTAssertEqual(s.phase, .recording)
    }

    func testMediaServicesResetDuringInterruptionRebuildsOnResume() {
        var s = RecorderState()
        _ = s.handle(.start)
        _ = s.handle(.interruptionBegan)
        XCTAssertEqual(s.handle(.mediaServicesReset), [])
        XCTAssertTrue(s.needsRebuild)
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: true)), [.rebuildSession])
        XCTAssertFalse(s.needsRebuild)
        // The next interruption resumes normally again.
        _ = s.handle(.interruptionBegan)
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: true)), [.resumeCapture])
    }

    func testEventsOutsideARecordingChangeNothing() {
        var s = RecorderState()
        for event: RecorderState.Event in [.stop, .interruptionBegan, .interruptionEnded(shouldResume: true),
                                            .resume, .mediaServicesReset] {
            XCTAssertEqual(s.handle(event), [], "\(event)")
            XCTAssertEqual(s.phase, .idle)
        }
    }

    func testStartWhileRecordingIsIgnored() {
        var s = RecorderState()
        _ = s.handle(.start)
        XCTAssertEqual(s.handle(.start), [])
        XCTAssertEqual(s.phase, .recording)
    }

    func testResumeWhileRecordingIsIgnored() {
        var s = RecorderState()
        _ = s.handle(.start)
        XCTAssertEqual(s.handle(.resume), [])
        XCTAssertEqual(s.handle(.interruptionEnded(shouldResume: true)), [])
        XCTAssertEqual(s.phase, .recording)
    }

    func testANewRecordingStartsClean() {
        var s = RecorderState()
        _ = s.handle(.start)
        _ = s.handle(.interruptionBegan)
        _ = s.handle(.mediaServicesReset)
        _ = s.handle(.stop)
        XCTAssertFalse(s.needsRebuild)
        XCTAssertEqual(s.handle(.start), [.beginCapture])
        XCTAssertEqual(s.interruptions, 0)
        XCTAssertFalse(s.needsRebuild)
    }

    func testInterruptionsAreCounted() {
        var s = RecorderState()
        _ = s.handle(.start)
        for _ in 0..<3 {
            _ = s.handle(.interruptionBegan)
            _ = s.handle(.interruptionEnded(shouldResume: true))
        }
        XCTAssertEqual(s.interruptions, 3)
    }
}
