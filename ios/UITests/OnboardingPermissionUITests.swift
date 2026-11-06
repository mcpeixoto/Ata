import XCTest

/// App Review rejected 3.1.2 under guideline 5.1.1(iv): the onboarding showed
/// an "Allow" button before the system's microphone prompt. A button that only
/// leads to that prompt has to say "Continue" or "Next".
final class OnboardingPermissionUITests: XCTestCase {
    @MainActor
    func testPermissionButtonsSayContinue() throws {
        let app = XCUIApplication()
        // Undecided, so the microphone button is there to read.
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = [
            "-AtaSnapshots", "onboarding",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-onboarded", "YES",
        ]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-onboarding-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment = [
            "ATA_MEETINGS_DIR": folder.appendingPathComponent("meetings").path,
            "ATA_SUPPORT_DIR": folder.appendingPathComponent("support").path,
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Ata"].waitForExistence(timeout: 30),
                      "the onboarding did not come up")

        let mic = app.buttons["microphone-permission"]
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        XCTAssertEqual(mic.label, "Continue")

        // Already answered on this simulator when it is missing; there is no
        // reset for notifications.
        let notifications = app.buttons["notifications-permission"]
        if notifications.exists {
            XCTAssertEqual(notifications.label, "Continue")
        }

        XCTAssertFalse(app.buttons["Allow"].exists)
        app.terminate()
    }
}
