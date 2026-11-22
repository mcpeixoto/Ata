import XCTest

/// The Ata Pro paywall: both plans, the close control, the trial when yearly is
/// selected, the renewal sentence built from the price on screen, Restore,
/// Terms and Privacy. The price is whatever the product (or the snapshot
/// fixture standing in for it) is showing — the test does not contain one.
/// Photographed in light and dark like the other screens.
final class PaywallUITests: XCTestCase {
    @MainActor
    func testPaywallShowsPriceAndRestore() throws {
        for appearance in ["light", "dark"] {
            let app = launch("paywall", appearance: appearance)

            let yearly = app.buttons["plan-yearly"]
            XCTAssertTrue(yearly.waitForExistence(timeout: 30), "the paywall did not come up")
            let monthly = app.buttons["plan-monthly"]
            XCTAssertTrue(monthly.exists)
            XCTAssertTrue(yearly.isSelected)
            XCTAssertFalse(monthly.isSelected)

            let subscribe = app.buttons["subscribe"]
            XCTAssertTrue(subscribe.exists)
            XCTAssertTrue(subscribe.isEnabled)
            XCTAssertTrue(subscribe.label.contains("free"), "yearly opens on the trial")
            XCTAssertTrue(yearly.label.contains("free"))

            let renewal = app.staticTexts["renewal"]
            XCTAssertTrue(renewal.exists)
            let price = try XCTUnwrap(priceToken(in: yearly.label), "the yearly card has no price")
            XCTAssertNotEqual(price, priceToken(in: monthly.label))
            XCTAssertTrue(renewal.label.contains(price), "the renewal sentence uses the selected plan's price")
            XCTAssertTrue(app.staticTexts["trial-timeline"].exists)

            XCTAssertTrue(app.buttons["close"].exists)
            XCTAssertTrue(app.buttons["restore"].exists)
            XCTAssertTrue(app.links["Terms"].exists || app.buttons["Terms"].exists)
            XCTAssertTrue(app.links["Privacy"].exists || app.buttons["Privacy"].exists)
            XCTAssertTrue(app.staticTexts["Every meeting, written up."].exists)

            Thread.sleep(forTimeInterval: 1.0)
            save(XCUIScreen.main.screenshot(), as: "iphone-paywall-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testTheLimitPaywallAndTheMonthlyPlan() throws {
        let limit = launch("paywall-limit", appearance: "light")
        XCTAssertTrue(limit.staticTexts["This month's free minutes are used."].waitForExistence(timeout: 30))
        XCTAssertTrue(limit.buttons["plan-yearly"].isSelected)
        XCTAssertTrue(limit.buttons["close"].exists)
        limit.terminate()

        let monthly = launch("paywall-monthly", appearance: "light")
        XCTAssertTrue(monthly.buttons["plan-monthly"].waitForExistence(timeout: 30))
        XCTAssertTrue(monthly.buttons["plan-monthly"].isSelected)
        XCTAssertFalse(monthly.buttons["plan-yearly"].isSelected)
        XCTAssertEqual(monthly.buttons["subscribe"].label, "Subscribe")
        XCTAssertFalse(monthly.staticTexts["trial-timeline"].exists)
        let renewal = monthly.staticTexts["renewal"]
        XCTAssertTrue(renewal.exists)
        let price = try XCTUnwrap(priceToken(in: monthly.buttons["plan-monthly"].label))
        XCTAssertTrue(renewal.label.contains(price))
        monthly.terminate()
    }

    /// The first currency amount on the control, as the product formatted it.
    private func priceToken(in label: String) -> String? {
        guard let match = label.range(of: #"\$[0-9]+[.,][0-9]{2}|[0-9]+[.,][0-9]{2}\s*€"#,
                                      options: .regularExpression) else { return nil }
        return String(label[match])
    }

    @MainActor
    private func launch(_ screen: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AtaSnapshots", screen,
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
