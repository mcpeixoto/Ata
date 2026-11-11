@testable import Ata
import XCTest

/// The time left under a transcribing meeting, and how the bar splits between tracks.
final class TranscribeETATests: XCTestCase {
    private func record(_ model: String, audio: Double, took: Double, daysAgo: Double = 1) -> TranscriptionRecord {
        TranscriptionRecord(engine: "local", model: model, finishedAt: Date().addingTimeInterval(-daysAgo * 86_400),
                            audioSeconds: audio, processingSeconds: took, costUSD: 0, words: 100,
                            mySpeechSeconds: 0, othersSpeechSeconds: 0, archivedAs: nil)
    }

    // MARK: Pace

    func testPaceIsTheMedianOfThisModelsRuns() {
        let records = [record("large", audio: 3600, took: 600), record("large", audio: 3600, took: 1800),
                       record("large", audio: 3600, took: 900), record("turbo", audio: 3600, took: 100)]
        XCTAssertEqual(TranscribeETA.rate(records, model: "large") ?? 0, 0.25, accuracy: 1e-9)
    }

    func testOnlyTheLastTenRunsCount() {
        let old = (0..<20).map { record("large", audio: 3600, took: 3600, daysAgo: 30 + Double($0)) }
        let recent = (0..<10).map { record("large", audio: 3600, took: 360, daysAgo: Double($0)) }
        XCTAssertEqual(TranscribeETA.rate(old + recent, model: "large") ?? 0, 0.1, accuracy: 1e-9)
    }

    func testNoPaceWithoutRunsOfThatModel() {
        XCTAssertNil(TranscribeETA.rate([record("turbo", audio: 3600, took: 100)], model: "large"))
        XCTAssertNil(TranscribeETA.rate([record("large", audio: 20, took: 10)], model: "large"))
    }

    // MARK: Time left

    func testEarlyOnTheHistoryDecides() {
        let left = TranscribeETA.remaining(progress: 0.02, elapsed: 60, expected: 1200)
        XCTAssertEqual(left ?? 0, 1140, accuracy: 1e-9)
    }

    func testNothingToSayWithoutHistoryOrProgress() {
        XCTAssertNil(TranscribeETA.remaining(progress: 0.02, elapsed: 60, expected: nil))
    }

    func testTheBarsPaceWithoutHistory() {
        // A quarter done in five minutes: fifteen to go.
        XCTAssertEqual(TranscribeETA.remaining(progress: 0.25, elapsed: 300, expected: nil) ?? 0, 900, accuracy: 1e-9)
    }

    func testTheBarWeighsMoreAsItGoes() {
        // History says 10 minutes in all; the bar says it's running twice as slow.
        let early = TranscribeETA.remaining(progress: 0.2, elapsed: 240, expected: 600)!
        let late = TranscribeETA.remaining(progress: 0.8, elapsed: 960, expected: 600)!
        XCTAssertEqual(early, 0.2 * 960 + 0.8 * 360, accuracy: 1e-9)
        XCTAssertEqual(late, 0.8 * 240 + 0.2 * 0, accuracy: 1e-9)
    }

    func testNeverNegative() {
        XCTAssertEqual(TranscribeETA.remaining(progress: 0.05, elapsed: 900, expected: 600) ?? -1, 0)
    }

    func testText() {
        XCTAssertEqual(TranscribeETA.text(20), L("Less than a minute left"))
        XCTAssertEqual(TranscribeETA.text(12 * 60), L("About %d min left", 12))
        XCTAssertEqual(TranscribeETA.text(83 * 60), L("About %d h %d min left", 1, 23))
    }

    // MARK: The bar

    func testTracksShareTheBarByHowMuchTheyHold() {
        let spans = Transcriber.ProgressShare.trackSpans(audible: [600, 1800])
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].base, 0, accuracy: 1e-9)
        XCTAssertEqual(spans[0].span, 0.25, accuracy: 1e-9)
        XCTAssertEqual(spans[1].base, 0.25, accuracy: 1e-9)
        XCTAssertEqual(spans[1].span, 0.75, accuracy: 1e-9)
    }

    func testANearSilentTrackStillMovesTheBar() {
        let spans = Transcriber.ProgressShare.trackSpans(audible: [0, 3600])
        XCTAssertGreaterThan(spans[0].span, 0)
        XCTAssertEqual(spans.reduce(0) { $0 + $1.span }, 1, accuracy: 1e-9)
        XCTAssertEqual(spans[1].base + spans[1].span, 1, accuracy: 1e-9)
    }

    func testSilentTracksSplitEvenly() {
        let spans = Transcriber.ProgressShare.trackSpans(audible: [0, 0])
        XCTAssertEqual(spans[0].span, 0.5, accuracy: 1e-9)
        XCTAssertTrue(Transcriber.ProgressShare.trackSpans(audible: []).isEmpty)
    }

    func testSpeechFillsItsStretchOfTheBar() {
        typealias Share = Transcriber.ProgressShare
        XCTAssertEqual(Share.forSpeech(0), Share.prepared, accuracy: 1e-9)
        XCTAssertEqual(Share.forSpeech(1), Share.speech, accuracy: 1e-9)
        XCTAssertEqual(Share.forSpeech(2), Share.speech, accuracy: 1e-9)
    }
}
