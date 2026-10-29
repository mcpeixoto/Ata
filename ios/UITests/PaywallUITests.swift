import XCTest

/// The Ata Pro paywall as it shows when the free meetings run out: the price
/// with its period, the renewal terms, Restore Purchases and the two links the
/// App Store requires. Photographed in light and dark like the other screens.
final class PaywallUITests: XCTestCase {
    @MainActor
    func testPaywallShowsPriceAndRestore() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)

            let price = app.buttons["subscribe"]
            XCTAssertTrue(price.waitForExistence(timeout: 30), "the paywall did not come up")
            XCTAssertEqual(price.label, "Subscribe for €2.99 / month")
            XCTAssertTrue(price.isEnabled)
            XCTAssertTrue(app.buttons["Restore Purchases"].exists)
            XCTAssertTrue(app.staticTexts["0 of 5 free meetings left this month"].exists)
            XCTAssertTrue(app.staticTexts["Renews monthly until cancelled. Cancel any time in Settings."].exists)
            XCTAssertTrue(app.links["Terms of Use"].exists || app.buttons["Terms of Use"].exists)
            XCTAssertTrue(app.links["Privacy Policy"].exists || app.buttons["Privacy Policy"].exists)

            Thread.sleep(forTimeInterval: 1.0)
            save(XCUIScreen.main.screenshot(), as: "iphone-paywall-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AtaSnapshots", "paywall",
            "-AtaSnapshotAppearance", appearance,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-onboarded", "YES",
        ]
        // An empty library of its own: the paywall needs no meetings, and the
        // simulator's are never read.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-paywall-\(UUID().uuidString)", isDirectory: true)
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
