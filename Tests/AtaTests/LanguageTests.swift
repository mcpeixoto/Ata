@testable import Ata
import XCTest

final class LanguageChoiceTests: XCTestCase {
    let ptUser = ["pt", "en"]

    func testConfidentPlausibleDetectionsAreUsed() {
        XCTAssertEqual(LanguageChoice.pick([("pt", 0.97), ("en", 0.91)], plausible: ptUser), ["pt", "en"])
    }

    func testConfidentButImplausibleLanguagesAreRejected() {
        // Large v3 heard UK English as Welsh at p 0.89–0.99.
        XCTAssertEqual(LanguageChoice.pick([("pt", 0.95), ("cy", 0.97)], plausible: ptUser), ["pt", "pt"])
    }

    func testAnUnsureTrackBorrowsTheOtherTracksAnswer() {
        // A quiet mic track misheard as Russian at low confidence.
        XCTAssertEqual(LanguageChoice.pick([("ru", 0.41), ("pt", 0.93)], plausible: ptUser), ["pt", "pt"])
        XCTAssertEqual(LanguageChoice.pick([nil, ("en", 0.88)], plausible: ptUser), ["en", "en"])
    }

    func testNothingConfidentFallsBackToTheMainLanguage() {
        XCTAssertEqual(LanguageChoice.pick([("es", 0.5), nil], plausible: ptUser), ["pt", "pt"])
        XCTAssertEqual(LanguageChoice.pick([nil], plausible: []), ["en"])
    }

    func testEnglishIsAlwaysPlausible() {
        XCTAssertTrue(LanguageChoice.plausible.contains("en"))
    }

    func testWhisperDetectionLineIsParsed() {
        let log = """
        whisper_init_from_file: loading model
        whisper_full_with_state: auto-detected language: pt (p = 0.973118)
        """
        let d = LocalEngine.parseDetection(log)
        XCTAssertEqual(d?.code, "pt")
        XCTAssertEqual(d?.p ?? 0, 0.973118, accuracy: 1e-6)
        XCTAssertNil(LocalEngine.parseDetection("no detection here"))
    }

    func testDecodingFlagsTurnContextOffAndNeverPrompt() {
        XCTAssertTrue(LocalEngine.decoding.contains("-mc"))
        XCTAssertEqual(LocalEngine.decoding[LocalEngine.decoding.firstIndex(of: "-mc")! + 1], "0")
        XCTAssertFalse(LocalEngine.decoding.contains("--prompt"))
    }
}
