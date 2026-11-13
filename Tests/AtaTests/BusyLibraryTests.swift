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

    // MARK: Language detection

    private let second = Int(WavWriter.sampleRate)

    /// Pieces of `lengths` seconds, back to back.
    private func pieces(_ lengths: [Int]) -> [Range<Int>] {
        var at = 0
        return lengths.map { n in
            defer { at += n * second }
            return at..<(at + n * second)
        }
    }

    func testNeighbouringPiecesShareOneDetectionWindow() {
        let windows = DetectionWindows.group(pieces([8, 8, 8, 8, 8, 8]), limitSamples: 30 * second)
        XCTAssertEqual(windows, [0..<3, 3..<6])
    }

    func testAPieceAsLongAsAWindowStandsAlone() {
        let windows = DetectionWindows.group(pieces([30, 5, 30]), limitSamples: 30 * second)
        XCTAssertEqual(windows, [0..<1, 1..<2, 2..<3])
    }

    func testEveryPieceIsInExactlyOneWindow() {
        let lengths = [4, 12, 29, 6, 6, 6, 6, 6, 18, 9, 30, 4, 4]
        let windows = DetectionWindows.group(pieces(lengths), limitSamples: 30 * second)
        XCTAssertEqual(windows.flatMap { Array($0) }, Array(lengths.indices))
        XCTAssertLessThan(windows.count, lengths.count)
        XCTAssertTrue(DetectionWindows.group([], limitSamples: 30 * second).isEmpty)
    }

    func testAnHourOfShortTurnsNeedsFarFewerPasses() {
        // About what an hour-long call split into: 427 pieces of ~8.7 s.
        let windows = DetectionWindows.group(pieces(Array(repeating: 9, count: 400)), limitSamples: DetectionWindows.limitSamples)
        XCTAssertLessThanOrEqual(windows.count, 134)
    }

    func testEachPieceTakesItsWindowsAnswer() {
        let spread = DetectionWindows.spread([("pt", 0.9), nil, ("en", 0.8)], over: [0..<2, 2..<3, 3..<5], pieces: 5)
        XCTAssertEqual(spread.map { $0?.code }, ["pt", "pt", nil, "en", "en"])
        XCTAssertEqual(spread[4]?.p ?? 0, 0.8, accuracy: 1e-9)
    }

    // MARK: Summaries

    func testEveryTranscriptWithWordsOwesASummaryWhenSummariesAreOn() {
        XCTAssertTrue(SummaryBackfill.owed(summarize: true, words: 12))
        XCTAssertFalse(SummaryBackfill.owed(summarize: true, words: 0))
        XCTAssertFalse(SummaryBackfill.owed(summarize: false, words: 12))
    }

    func testEveryStageSaysSomethingDifferent() {
        let stages: [TranscribeStage] = [.preparing, .languages, .speechModel, .speech, .voices, .summary]
        XCTAssertEqual(Set(stages.map(\.label)).count, stages.count)
        XCTAssertEqual(TranscribeStage.speechModel.label, "Downloading speech model…")
    }
}
