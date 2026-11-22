import XCTest

/// The App Store review sheet: after the third successful transcript, never
/// while recording, once per version, and not on a day the Pro sheet was shown.
final class ReviewPromptTests: XCTestCase {
    func testAsksAfterTheThirdTranscriptOncePerVersion() {
        XCTAssertFalse(ReviewPrompt.shouldRequest(successfulTranscripts: 2, isRecording: false,
                                                  lastPromptedVersion: nil, currentVersion: "4.0",
                                                  proSheetShownToday: false))
        XCTAssertTrue(ReviewPrompt.shouldRequest(successfulTranscripts: 3, isRecording: false,
                                                 lastPromptedVersion: nil, currentVersion: "4.0",
                                                 proSheetShownToday: false))
        XCTAssertTrue(ReviewPrompt.shouldRequest(successfulTranscripts: 5, isRecording: false,
                                                 lastPromptedVersion: nil, currentVersion: "4.0",
                                                 proSheetShownToday: false))
        XCTAssertFalse(ReviewPrompt.shouldRequest(successfulTranscripts: 3, isRecording: true,
                                                  lastPromptedVersion: nil, currentVersion: "4.0",
                                                  proSheetShownToday: false))
        XCTAssertFalse(ReviewPrompt.shouldRequest(successfulTranscripts: 4, isRecording: false,
                                                  lastPromptedVersion: "4.0", currentVersion: "4.0",
                                                  proSheetShownToday: false))
        XCTAssertTrue(ReviewPrompt.shouldRequest(successfulTranscripts: 4, isRecording: false,
                                                 lastPromptedVersion: "3.9", currentVersion: "4.0",
                                                 proSheetShownToday: false))
        XCTAssertFalse(ReviewPrompt.shouldRequest(successfulTranscripts: 3, isRecording: false,
                                                  lastPromptedVersion: nil, currentVersion: "4.0",
                                                  proSheetShownToday: true))
        XCTAssertFalse(ReviewPrompt.shouldRequest(successfulTranscripts: 3, isRecording: false,
                                                  lastPromptedVersion: nil, currentVersion: "",
                                                  proSheetShownToday: false))
    }
}
