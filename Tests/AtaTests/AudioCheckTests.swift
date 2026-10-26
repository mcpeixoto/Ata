@testable import Ata
import XCTest

/// Noticing that a recording came out the wrong length.
///
/// This is the check that would have turned "sometimes the transcript is
/// nonsense and the voice sounds sped up" into a log line naming the
/// microphone format that caused it.
final class AudioCheckTests: XCTestCase {
    func testARecordingThatMatchesTheClockIsFine() {
        XCTAssertFalse(AudioCheck.isSuspect(audioSeconds: 600, elapsed: 600))
        XCTAssertFalse(AudioCheck.isSuspect(audioSeconds: 598, elapsed: 600), "a moment lost at either end")
    }

    /// Three times fast is what a 48 kHz microphone written as 16 kHz gives.
    func testAudioThreeTimesTooShortIsCaught() {
        XCTAssertTrue(AudioCheck.isSuspect(audioSeconds: 200, elapsed: 600))
    }

    func testAudioThatRanLongIsCaughtToo() {
        XCTAssertTrue(AudioCheck.isSuspect(audioSeconds: 1_800, elapsed: 600))
    }

    /// A two-second clip is not evidence of anything, and a false alarm would
    /// teach people to ignore the real one.
    func testAVeryShortRecordingIsNotJudged() {
        XCTAssertFalse(AudioCheck.isSuspect(audioSeconds: 1, elapsed: 3))
        XCTAssertNil(AudioCheck.drift(audioSeconds: 1, elapsed: 3))
        XCTAssertNil(AudioCheck.drift(audioSeconds: 0, elapsed: 600), "nothing was recorded at all")
    }

    func testDriftIsAShareOfTheTimeItRan() {
        XCTAssertEqual(try XCTUnwrap(AudioCheck.drift(audioSeconds: 300, elapsed: 600)), -0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(AudioCheck.drift(audioSeconds: 660, elapsed: 600)), 0.1, accuracy: 1e-9)
    }

    /// The log line has to carry the evidence, or it is just a complaint.
    func testTheReportNamesTheSpeedAndTheFormats() {
        let line = AudioCheck.report(audioSeconds: 200, elapsed: 600, formats: ["48000 Hz × 2"])
        XCTAssertTrue(line.contains("3.0× too fast"), line)
        XCTAssertTrue(line.contains("48000 Hz × 2"), line)

        let slow = AudioCheck.report(audioSeconds: 600, elapsed: 200, formats: [])
        XCTAssertTrue(slow.contains("too slow"), slow)
        XCTAssertTrue(slow.contains("unknown"), "say so rather than printing an empty list")
    }
}
