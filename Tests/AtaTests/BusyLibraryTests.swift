@testable import Ata
import Combine
import XCTest

/// A long history, a call being recorded and another being transcribed at
/// once: what keeps the menu bar responsive and the queue moving.
final class BusyLibraryTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    // MARK: Progress

    @MainActor
    func testProgressOnlyPublishesAWholePercent() {
        let live = LiveValues()
        var published = 0
        let watch = live.$transcribeProgress.dropFirst().sink { _ in published += 1 }
        defer { watch.cancel() }
        live.setProgress(0.101)
        live.setProgress(0.104)
        live.setProgress(0.109)
        XCTAssertEqual(published, 1)
        live.setProgress(0.11)
        XCTAssertEqual(published, 2)
        XCTAssertEqual(live.transcribeProgress, 0.11, accuracy: 1e-9)
    }

    func testPercentIsClamped() {
        XCTAssertEqual(LiveValues.percent(-0.2), 0)
        XCTAssertEqual(LiveValues.percent(0.999), 99)
        XCTAssertEqual(LiveValues.percent(1.5), 100)
    }

    func testVoicesAndSummaryHaveRoomOnTheBar() {
        XCTAssertLessThan(Transcriber.ProgressShare.speech, Transcriber.ProgressShare.summary)
        XCTAssertLessThan(Transcriber.ProgressShare.summary, 1)
        XCTAssertLessThanOrEqual(Transcriber.ProgressShare.speech, 0.9)
    }

    // MARK: The iCloud watcher

    private let folder = URL(fileURLWithPath: "/Library/Ata/Meetings/2026-11-11 Slack", isDirectory: true)

    func testScratchFilesOfATranscriptionAreNotChanges() {
        XCTAssertFalse(CloudWatcher.countsAsChange(folder.appendingPathComponent("languages-1a2b3c4d/piece-12.wav")))
        XCTAssertFalse(CloudWatcher.countsAsChange(folder.appendingPathComponent("mic.decoded.wav")))
        XCTAssertFalse(CloudWatcher.countsAsChange(folder.appendingPathComponent("mic.echo-cancelled.wav")))
        XCTAssertFalse(CloudWatcher.countsAsChange(folder.appendingPathComponent(".transcript-1a2b3c4d.md")))
    }

    func testTheLibrarysOwnFilesAreChanges() {
        for name in ["meeting.json", "transcript.md", "transcript.json", "notes.md", "mic.wav", "meeting.mp3"] {
            XCTAssertTrue(CloudWatcher.countsAsChange(folder.appendingPathComponent(name)), name)
        }
    }

    func testAudioBeingWrittenIsNotAChangeButItsListingIs() {
        XCTAssertFalse(CloudWatcher.editCountsAsChange(folder.appendingPathComponent("mic.wav")))
        XCTAssertFalse(CloudWatcher.editCountsAsChange(folder.appendingPathComponent("meeting.mp3")))
        XCTAssertFalse(CloudWatcher.editCountsAsChange(folder.appendingPathComponent("system.m4a")))
        XCTAssertTrue(CloudWatcher.editCountsAsChange(folder.appendingPathComponent("meeting.json")))
        XCTAssertTrue(CloudWatcher.editCountsAsChange(folder.appendingPathComponent("transcript.md")))
    }

    func testChangesSettleLongerThanOneQueryBatch() {
        XCTAssertGreaterThan(CloudWatcher.settleSeconds, 1)
    }

    // MARK: The queue

    private func meeting(_ id: String, _ status: Meeting.Status, minutesAgo: Double) -> Meeting {
        var m = Meeting(id: id, startedAt: Date().addingTimeInterval(-minutesAgo * 60), endedAt: nil,
                        duration: 60, app: nil, status: status, error: nil)
        m.origin = Device.current
        return m
    }

    func testQueueTakesTheOldestWaitingMeeting() {
        // Newest first, as the library lists them.
        let all = [meeting("busy-new", .pending, minutesAgo: 5), meeting("busy-done", .done, minutesAgo: 30),
                   meeting("busy-old", .pending, minutesAgo: 90)]
        XCTAssertEqual(AppStore.nextInQueue(all, repairing: [], now: Date())?.id, "busy-old")
    }

    func testQueueSkipsMeetingsTheRepairScanHasNotReached() {
        let all = [meeting("busy-new", .pending, minutesAgo: 5), meeting("busy-old", .pending, minutesAgo: 90)]
        XCTAssertEqual(AppStore.nextInQueue(all, repairing: ["busy-old"], now: Date())?.id, "busy-new")
        XCTAssertNil(AppStore.nextInQueue(all, repairing: ["busy-old", "busy-new"], now: Date()))
    }

    func testNothingFinishedIsQueued() {
        let all = [meeting("busy-a", .done, minutesAgo: 5), meeting("busy-b", .failed, minutesAgo: 9),
                   meeting("busy-c", .recording, minutesAgo: 1)]
        XCTAssertNil(AppStore.nextInQueue(all, repairing: [], now: Date()))
    }
}
