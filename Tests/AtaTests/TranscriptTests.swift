@testable import Ata
import XCTest

final class EchoRemovalTests: XCTestCase {
    func testMicLinesThatRepeatTheOthersAreDropped() {
        let segments = [
            Segment(speaker: "Others", start: 1_000, end: 4_000, text: "Shall we move the launch to Thursday then"),
            // The mic heard the speakers: same words, same moment.
            Segment(speaker: "Alex", start: 1_200, end: 4_100, text: "shall we move the launch to Thursday"),
            // Alex actually talking, later.
            Segment(speaker: "Alex", start: 6_000, end: 8_000, text: "Yes, Thursday works for me"),
        ]
        let kept = Transcriber.removeEcho(segments, me: "Alex")
        XCTAssertEqual(kept.map(\.text), ["Shall we move the launch to Thursday then", "Yes, Thursday works for me"])
    }

    func testOverlappingButDifferentSpeechIsKept() {
        let segments = [
            Segment(speaker: "Others", start: 0, end: 3_000, text: "The numbers look good this quarter"),
            Segment(speaker: "Alex", start: 500, end: 2_500, text: "Sorry, can you share your screen"),
        ]
        XCTAssertEqual(Transcriber.removeEcho(segments, me: "Alex").count, 2)
    }
}

final class TalkTimeTests: XCTestCase {
    func testTimedSegmentsSumTheirDurations() {
        let segments = [
            Segment(speaker: "Alex", start: 0, end: 4_000, text: "one two"),
            Segment(speaker: "Others", start: 4_000, end: 10_000, text: "three four five"),
        ]
        let talk = Transcriber.talkTime(segments, me: "Alex", coarse: false)
        XCTAssertEqual(talk.me, 4, accuracy: 1e-9)
        XCTAssertEqual(talk.others, 6, accuracy: 1e-9)
    }

    func testCoarseSegmentsAreEstimatedFromWords() {
        let segments = [Segment(speaker: "Alex", start: 0, end: 0, text: "one two three four five")]
        XCTAssertEqual(Transcriber.talkTime(segments, me: "Alex", coarse: true).me, 2, accuracy: 1e-9)
    }

    func testWordCountIgnoresPunctuation() {
        XCTAssertEqual(Transcriber.wordCount("Olá — tudo bem? Sim, 100%."), 5)
    }
}

final class OverrideTests: XCTestCase {
    func testAOneOffModelChoiceWinsOverSettings() {
        var m = Meeting(id: "t", startedAt: Date(), endedAt: nil, duration: nil, app: nil, status: .pending, error: nil)
        m.override = TranscribeOverride(engine: "apple", model: AppleSpeechEngine.modelID)
        let o = TranscribeOptions.current(for: m)
        XCTAssertEqual(o.engine, .apple)
        XCTAssertEqual(o.modelID, AppleSpeechEngine.modelID)

        m.override = TranscribeOverride(engine: "local", model: "large-v3")
        let local = TranscribeOptions.current(for: m)
        XCTAssertEqual(local.engine, .local)
        XCTAssertEqual(local.modelID, "large-v3")
    }
}
