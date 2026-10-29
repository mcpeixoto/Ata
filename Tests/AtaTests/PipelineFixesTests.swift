@testable import Ata
import XCTest

/// Fixes from a review of the Mac pipeline: what "don't keep audio" and
/// storage count, a transcript never lost to a failed write, a noisy remote
/// participant's words kept, a cancelled whisper stopped, and a calendar
/// auto-start retried when it failed.
final class PipelineFixesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        // The library location is resolved once per process, so every suite
        // shares FilesTests' temporary folders rather than making its own.
        FilesTests.setUp()
    }

    // MARK: 6. The repair's backups are audio too

    func testTheRepairBackupCountsAsAudioAndGoesWithIt() throws {
        let m = try Meeting.new(app: "Zoom")
        let wav = WavWriter.header(dataBytes: 1_000) + Data(count: 1_000)
        try wav.write(to: m.micURL)
        try wav.write(to: m.systemURL)
        let backup = m.dir.appendingPathComponent("system.corrupted.m4a")
        try Data(count: 5_000).write(to: backup)

        XCTAssertEqual(m.repairBackupURLs, [backup])
        XCTAssertEqual(m.audioBytes, 1_044 + 1_044 + 5_000, "storage counts the kept original")
        XCTAssertTrue(m.audioFilesToDiscard.contains(backup), "\"don't keep audio\" removes it")
        XCTAssertTrue(m.keptAudioFiles.contains(backup), "retention removes it")
        XCTAssertFalse(m.audioFilesToDiscard.contains(m.transcriptURL))
    }

    // MARK: 8. A failed write leaves the earlier transcript in place

    func testAFailedWriteKeepsTheEarlierTranscript() throws {
        let m = try Meeting.new(app: "Teams")
        try "first".write(to: m.transcriptURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try Transcriber.replaceTranscript(of: m, with: "second") { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try String(contentsOf: m.transcriptURL, encoding: .utf8), "first")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: m.versionsDir.path)) ?? []
        XCTAssertTrue(versions.isEmpty, "nothing was archived")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: m.dir.path).filter { $0.hasPrefix(".transcript-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testANewTranscriptArchivesTheEarlierOne() throws {
        let m = try Meeting.new(app: "Meet")
        try "first".write(to: m.transcriptURL, atomically: true, encoding: .utf8)

        let archived = try XCTUnwrap(try Transcriber.replaceTranscript(of: m, with: "second"))
        XCTAssertEqual(try String(contentsOf: m.transcriptURL, encoding: .utf8), "second")
        XCTAssertEqual(try String(contentsOf: m.versionsDir.appendingPathComponent(archived), encoding: .utf8), "first")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: m.dir.path).filter { $0.hasPrefix(".transcript-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testAFirstTranscriptHasNothingToArchive() throws {
        let m = try Meeting.new(app: "Slack")
        XCTAssertNil(try Transcriber.replaceTranscript(of: m, with: "only"))
        XCTAssertEqual(try String(contentsOf: m.transcriptURL, encoding: .utf8), "only")
    }

    // MARK: 4. The other side's lines survive the in-person path

    /// A noisy remote participant: a loud system track with little speech.
    /// The microphone is diarized, and the remote lines stay as they were.
    func testTheSystemTracksLinesSurviveWhenTheMicrophoneIsDiarized() {
        let loud = [UInt8](repeating: 200, count: 344 * 1000 / Waveform.bucketMs)
        let choice = SpeakerRoute.decision(systemLevels: loud, hasMic: true, systemSpeechSeconds: 20)
        XCTAssertEqual(choice.route, .inPerson, "the heuristic still routes this to the microphone")

        let remote = Segment(speaker: Speakers.others, start: 1_000, end: 5_000, text: "Can you hear me now?")
        let words: [Segment.Word] = [
            .init(start: 6_000, end: 6_400, text: "Yes,"), .init(start: 6_400, end: 6_800, text: "fine."),
            .init(start: 9_100, end: 9_500, text: "Agreed."),
        ]
        let room = Segment(speaker: Speakers.me, start: 6_000, end: 9_500, text: "Yes, fine. Agreed.", words: words)
        let turns = [SpeakerTurn(start: 5_500, end: 8_000, label: Speakers.me),
                     SpeakerTurn(start: 8_000, end: 10_000, label: "S1")]

        let out = Transcriber.splitMicrophoneLines([remote, room], turns: turns)
        let kept = out.filter { $0.speaker == Speakers.others }
        XCTAssertEqual(kept.map(\.text), ["Can you hear me now?"], "the remote participant keeps their words")
        XCTAssertEqual(out.filter { $0.speaker != Speakers.others }.map(\.speaker), [Speakers.me, "S1"])
    }

    // MARK: 5. Cancelling a run stops the helper process

    #if os(macOS)
    func testCancellingARunTerminatesTheProcess() async throws {
        let started = Date()
        let run = Task {
            try await LocalEngine.runProcess(URL(fileURLWithPath: "/bin/sleep"), ["30"], progress: { _ in })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        run.cancel()
        do {
            _ = try await run.value
            XCTFail("a cancelled run must not finish as if it succeeded")
        } catch TranscriberError.cancelled {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the process was stopped, not waited for")
    }

    func testARunCancelledBeforeItStartsNeverStarts() async throws {
        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalEngine.runProcess(URL(fileURLWithPath: "/bin/sleep"), ["30"], progress: { _ in })
        }
        let started = Date()
        do {
            _ = try await run.value
            XCTFail("a cancelled run must not start")
        } catch TranscriberError.cancelled {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
    #endif

    // MARK: 10. A calendar auto-start that failed is tried again

    func testAFailedAutoStartIsRetriedAndASuccessIsNot() {
        var ledger = AutoStartLedger()
        XCTAssertTrue(ledger.mayStart("standup"))
        ledger.attempt("standup")
        XCTAssertFalse(ledger.mayStart("standup"), "not twice while the first start is still going")
        ledger.finished("standup", started: false)
        XCTAssertTrue(ledger.mayStart("standup"), "a start that failed is tried again")

        ledger.attempt("standup")
        ledger.finished("standup", started: true)
        XCTAssertFalse(ledger.mayStart("standup"), "a recording that started is not started again")
    }

    func testAutoStartGivesUpAfterAFewFailures() {
        var ledger = AutoStartLedger()
        for _ in 0..<AutoStartLedger.maxAttempts {
            XCTAssertTrue(ledger.mayStart("1:1"))
            ledger.attempt("1:1")
            ledger.finished("1:1", started: false)
        }
        XCTAssertFalse(ledger.mayStart("1:1"), "a start that keeps failing is not retried every twenty seconds")
        XCTAssertTrue(ledger.mayStart("review"), "other meetings are unaffected")
    }
}
