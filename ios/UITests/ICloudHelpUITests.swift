import XCTest

/// The way to the iCloud Drive switch, as the iPhone shows it when "Keep
/// meetings in iCloud" is turned on before iCloud Drive is. Photographed in
/// light and dark like the other screens.
final class ICloudHelpUITests: XCTestCase {
    @MainActor
    func testTheHelpShowsEveryStep() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)

            XCTAssertTrue(app.staticTexts["Open Settings and tap your name at the top."].waitForExistence(timeout: 30),
                          "the iCloud help did not come up")
            XCTAssertTrue(app.staticTexts["Tap iCloud, then iCloud Drive."].exists)
            XCTAssertTrue(app.staticTexts["Turn on Sync this iPhone."].exists)
            XCTAssertTrue(app.staticTexts["Turn on Ata in the list of apps below it."].exists)
            XCTAssertTrue(app.buttons["Not now"].exists)

            Thread.sleep(forTimeInterval: 1.0)
            save(XCUIScreen.main.screenshot(), as: "iphone-icloud-help-\(appearance)")

            app.buttons["Not now"].tap()
            XCTAssertTrue(app.staticTexts["Open Settings and tap your name at the top."].waitForNonExistence(timeout: 10),
                          "Not now closes it")
            app.terminate()
        }
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AtaSnapshots", "icloud-help",
            "-AtaSnapshotAppearance", appearance,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-onboarded", "YES",
        ]
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-icloud-help-\(UUID().uuidString)", isDirectory: true)
        app.launchEnvironment = [
            "ATA_MEETINGS_DIR": folder.appendingPathComponent("meetings").path,
            "ATA_SUPPORT_DIR": folder.appendingPathComponent("support").path,
        ]
        app.launch()
        return app
    }

    private func save(_ shot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let dir = ProcessInfo.processInfo.environment["ATA_SNAPSHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
    }
}
