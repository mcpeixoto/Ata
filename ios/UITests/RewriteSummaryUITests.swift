import XCTest

/// The iPhone paywall sells "your own summary formats", and a meeting's summary is
/// the only place one is used. 4.0.0 shipped that menu on the Mac only, so the
/// iPhone sold a feature it had no way to reach. This keeps it on the phone.
final class RewriteSummaryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAMeetingSummaryOffersRewrite() throws {
        let env = ProcessInfo.processInfo.environment
        let fixtures = try XCTUnwrap(env["ATA_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 },
                                     "Set TEST_RUNNER_ATA_FIXTURES to the folder ios/snapshots.sh makes")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-rewrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixtures, isDirectory: true), to: folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-AtaSnapshots", "meeting-notes",
            "-AtaSnapshotAppearance", "light",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-myName", "Alex", "-language", "auto", "-onboarded", "YES",
            "-keepAudio", "YES", "-recogniseVoices", "YES", "-summarize", "YES",
        ]
        app.launchEnvironment = [
            "ATA_MEETINGS_DIR": folder.appendingPathComponent("meetings").path,
            "ATA_SUPPORT_DIR": folder.appendingPathComponent("support").path,
        ]
        app.launch()

        let rewrite = app.buttons["Rewrite summary with"]
        XCTAssertTrue(rewrite.waitForExistence(timeout: 30),
                      "a meeting's summary should offer Rewrite summary with on the iPhone")
        rewrite.tap()
        XCTAssertTrue(app.buttons["Standard"].waitForExistence(timeout: 10)
                      || app.staticTexts["Standard"].waitForExistence(timeout: 2),
                      "the menu should list the built-in templates")
    }
}
