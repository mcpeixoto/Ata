@testable import Ata
import XCTest

/// Transcription backs off while a call is on, so the call doesn't stutter.
final class TranscriptionLoadTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    private func meeting(_ id: String, _ status: Meeting.Status, endedMinutesAgo: Double) -> Meeting {
        let end = Date().addingTimeInterval(-endedMinutesAgo * 60)
        var m = Meeting(id: id, startedAt: end.addingTimeInterval(-60), endedAt: end,
                        duration: 60, app: nil, status: status, error: nil)
        m.origin = Device.current
        return m
    }

    func testDuringACallWhisperGetsHalfThePerformanceCores() {
        XCTAssertEqual(TranscriptionLoad.threads(callActive: true, performanceCores: 8, allCores: 12), 4)
        XCTAssertEqual(TranscriptionLoad.threads(callActive: true, performanceCores: 4, allCores: 8), 2)
        // Never fewer than two, even on the smallest chip.
        XCTAssertEqual(TranscriptionLoad.threads(callActive: true, performanceCores: 2, allCores: 4), 2)
        // No perflevel key: half of half the cores.
        XCTAssertEqual(TranscriptionLoad.threads(callActive: true, performanceCores: nil, allCores: 8), 2)
    }

    func testWithoutACallWhisperKeepsItsUsualThreads() {
        XCTAssertEqual(TranscriptionLoad.threads(callActive: false, performanceCores: 8, allCores: 12), 10)
        XCTAssertEqual(TranscriptionLoad.threads(callActive: false, performanceCores: 4, allCores: 4), 4)
    }

    func testWhisperNeverRunsAtInteractivePriority() {
        XCTAssertEqual(TranscriptionLoad.processQoS, .utility)
    }

    func testDuringACallOnlyTheMeetingJustEndedStarts() {
        // Newest first, as the library lists them.
        let all = [meeting("load-new", .pending, endedMinutesAgo: 2),
                   meeting("load-old", .pending, endedMinutesAgo: 240)]
        XCTAssertEqual(AppStore.nextInQueue(all, repairing: [], now: Date(), callActive: false)?.id, "load-old")
        XCTAssertEqual(AppStore.nextInQueue(all, repairing: [], now: Date(), callActive: true)?.id, "load-new")
    }

    func testDuringACallTheBacklogWaits() {
        let all = [meeting("load-a", .pending, endedMinutesAgo: 45), meeting("load-b", .pending, endedMinutesAgo: 300)]
        XCTAssertNil(AppStore.nextInQueue(all, repairing: [], now: Date(), callActive: true))
        XCTAssertEqual(AppStore.nextInQueue(all, repairing: [], now: Date(), callActive: false)?.id, "load-b")
    }

    func testAMeetingWithNoEndUsesItsLength() {
        var m = meeting("load-open", .pending, endedMinutesAgo: 0)
        m.endedAt = nil
        m.startedAt = Date().addingTimeInterval(-3600)
        m.duration = 3600 - 60
        XCTAssertTrue(TranscriptionLoad.mayStart(m, callActive: true, now: Date()))
        m.duration = 60
        XCTAssertFalse(TranscriptionLoad.mayStart(m, callActive: true, now: Date()))
    }

    func testQuietWaitReturnsAtOnceWithNoCall() async {
        TranscriptionLoad.callActive = false
        let start = Date()
        await TranscriptionLoad.waitForQuiet(poll: 5)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testQuietWaitEndsWhenTheCallDoes() async {
        TranscriptionLoad.callActive = true
        let waiter = Task { await TranscriptionLoad.waitForQuiet(poll: 0.02) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        TranscriptionLoad.callActive = false
        let start = Date()
        await waiter.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
