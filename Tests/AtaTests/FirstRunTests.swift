@testable import Ata
import XCTest

final class FirstRunTests: XCTestCase {
    func testPermissionsComeFirst() {
        XCTAssertEqual(SetupStep.current(mic: false, systemAudioMissing: false, apple: .ready, summariesPassed: true), .recording)
        XCTAssertEqual(SetupStep.current(mic: true, systemAudioMissing: true, apple: .ready, summariesPassed: true), .recording)
    }

    func testAppleIntelligenceIsOnlyAskedAboutWhenItCanHelp() {
        func step(_ apple: AppleIntelligenceState, passed: Bool = false) -> SetupStep {
            SetupStep.current(mic: true, systemAudioMissing: false, apple: apple, summariesPassed: passed)
        }
        XCTAssertEqual(step(.off), .summaries)
        XCTAssertEqual(step(.preparing), .summaries)
        XCTAssertEqual(step(.ready), .done)
        XCTAssertEqual(step(.unsupported), .done, "a Mac that can't run it has nothing to turn on")
        XCTAssertEqual(step(.off, passed: true), .done, "it never blocks setup")
    }

    func testTheDownloadNeedsRoomAndAMargin() {
        let gb: Int64 = 1_000_000_000
        XCTAssertTrue(DiskCheck.hasRoom(available: 5 * gb, needed: gb))
        XCTAssertFalse(DiskCheck.hasRoom(available: gb, needed: gb), "exactly full is not room")
        XCTAssertTrue(DiskCheck.hasRoom(available: nil, needed: gb), "not knowing is no reason to refuse")
    }

    /// Found by quitting halfway for real: the resumed download arrived whole and
    /// was then thrown away, because only 200 counted as success.
    func testAResumedDownloadCountsAsFinished() {
        XCTAssertTrue(Downloader.isComplete(status: 200))
        XCTAssertTrue(Downloader.isComplete(status: 206))
        XCTAssertFalse(Downloader.isComplete(status: 404))
        XCTAssertFalse(Downloader.isComplete(status: 500))
    }

    func testOnlyApplicationsCountsAsSettled() {
        XCTAssertTrue(InstallLocation.isSettled("/Applications/Ata.app", home: "/Users/a"))
        XCTAssertTrue(InstallLocation.isSettled("/Users/a/Applications/Ata.app", home: "/Users/a"))
        XCTAssertFalse(InstallLocation.isSettled("/Users/a/Downloads/Ata.app", home: "/Users/a"))
        XCTAssertFalse(InstallLocation.isSettled("/Volumes/Ata/Ata.app", home: "/Users/a"))
        XCTAssertFalse(InstallLocation.isSettled("/private/var/folders/x/AppTranslocation/y/d/Ata.app", home: "/Users/a"))
    }

    func testAQueuedMeetingSaysWhatItIsWaitingFor() {
        XCTAssertNil(QueueReason.text(whisper: true, model: true, progress: nil, error: nil))
        XCTAssertTrue(QueueReason.text(whisper: true, model: false, progress: 0.64, error: nil)!.contains("64"))
        XCTAssertTrue(QueueReason.text(whisper: true, model: false, progress: nil, error: "offline")!.contains("offline"))
        XCTAssertNotNil(QueueReason.text(whisper: false, model: true, progress: nil, error: nil))
    }

    func testOnlyAMeetingWithSpeechIsOwedASummary() {
        XCTAssertTrue(SummaryBackfill.shouldMark(summarize: true, appleAvailable: false, words: 10))
        XCTAssertFalse(SummaryBackfill.shouldMark(summarize: true, appleAvailable: true, words: 10))
        XCTAssertFalse(SummaryBackfill.shouldMark(summarize: false, appleAvailable: false, words: 10))
        XCTAssertFalse(SummaryBackfill.shouldMark(summarize: true, appleAvailable: false, words: 0))
    }

    func testASummaryOwedStaysThroughStorageAndOldMeetingsLackIt() throws {
        var m = Meeting(id: "t", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, duration: nil, app: nil,
                        status: .done, error: nil)
        XCTAssertNil(try JSONDecoder.roundTrip(m).summaryPending)
        m.summaryPending = true
        XCTAssertEqual(try JSONDecoder.roundTrip(m).summaryPending, true)
    }

    func testAMutedMicrophoneIsNoticedButAQuietRoomIsNot() {
        XCTAssertTrue(Recorder.micIsSilent(micPeak: 0, systemPeak: 0.4, elapsed: 31))
        XCTAssertFalse(Recorder.micIsSilent(micPeak: 0, systemPeak: 0.4, elapsed: 29), "too early to say")
        XCTAssertFalse(Recorder.micIsSilent(micPeak: 0.02, systemPeak: 0.4, elapsed: 60), "room noise is not silence")
        XCTAssertFalse(Recorder.micIsSilent(micPeak: 0, systemPeak: 0, elapsed: 60), "nothing is happening yet")
    }
}

private extension JSONDecoder {
    static func roundTrip(_ m: Meeting) throws -> Meeting {
        try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(m))
    }
}

/// The script runs for real, against folders standing in for the app.
final class UpdateRollbackTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func run(_ script: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        p.waitUntilExit()
    }

    func testABuildThatDoesNotStartIsReplacedByTheOldOne() throws {
        let root = try folder()
        let app = root.appendingPathComponent("It's Ata.app"), backup = root.appendingPathComponent("old.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "new".write(to: app.appendingPathComponent("v"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try "old".write(to: backup.appendingPathComponent("v"), atomically: true, encoding: .utf8)

        // `open` that does nothing: the new copy never runs.
        try run(Updater.relaunchScript(app: app.path, backup: backup.path, open: "/usr/bin/true", settle: 0))

        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("v"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testABuildThatRunsDropsTheBackup() throws {
        let root = try folder()
        let app = root.appendingPathComponent("Ata.app"), backup = root.appendingPathComponent("old.app")
        let binary = app.appendingPathComponent("Contents/MacOS/Ata")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary.path)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        let running = Process()
        running.executableURL = binary
        running.arguments = ["5"]
        try running.run()
        defer { running.terminate() }

        try run(Updater.relaunchScript(app: app.path, backup: backup.path, open: "/usr/bin/true", settle: 0))

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))
    }
}
