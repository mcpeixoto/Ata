@testable import Ata
import XCTest

final class PricingTests: XCTestCase {
    func testTranscriptionIsPricedPerMinute() {
        XCTAssertEqual(Pricing.transcription(model: "whisper-1", seconds: 600), 0.06, accuracy: 1e-9)
        XCTAssertEqual(Pricing.transcription(model: "gpt-4o-mini-transcribe", seconds: 600), 0.03, accuracy: 1e-9)
    }

    func testUnknownTranscriptionModelFallsBackToTheStandardRate() {
        XCTAssertEqual(Pricing.transcription(model: "some-future-model", seconds: 60), 0.006, accuracy: 1e-9)
    }

    func testChatIsPricedPerMillionTokens() {
        // 1M input at $0.15 + 1M output at $0.60
        XCTAssertEqual(Pricing.chat(model: "gpt-4o-mini", inputTokens: 1_000_000, outputTokens: 1_000_000),
                       0.75, accuracy: 1e-9)
    }

    func testLocalSavingsUseTheWhisperRate() {
        XCTAssertEqual(Pricing.localSavings(seconds: 3600), 0.36, accuracy: 1e-9)
    }
}

final class UpdaterVersionTests: XCTestCase {
    func testTagsLoseTheirPrefix() {
        XCTAssertEqual(Updater.normalize("v2.2.0"), "2.2.0")
        XCTAssertEqual(Updater.normalize("2.2.0"), "2.2.0")
    }

    func testVersionsCompareNumerically() {
        XCTAssertTrue(Updater.isNewer("2.10.0", than: "2.9.0"))
        XCTAssertTrue(Updater.isNewer("2.2.0", than: "2.1.9"))
        XCTAssertTrue(Updater.isNewer("3", than: "2.99"))
        XCTAssertFalse(Updater.isNewer("2.2.0", than: "2.2.0"))
        XCTAssertFalse(Updater.isNewer("2.2", than: "2.2.0"))
        XCTAssertFalse(Updater.isNewer("2.1.0", than: "2.2.0"))
    }
}
