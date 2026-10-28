import XCTest

/// Screenshots of the iPhone app in light and dark, for reviewing the UI without
/// a device. Run by ios/snapshots.sh, locally or in CI.
///
/// Every screen is a fresh launch with `-AtaSnapshots <screen>` (see
/// Sources/AtaiOS/PhoneSnapshots.swift) and its own copy of the fixtures, so no
/// screen depends on what another one did. The fixtures folder, with
/// `meetings/` and `support/` from scripts/lib/make-fixtures.py, comes from
/// `ATA_FIXTURES`; PNGs are written to `ATA_SNAPSHOT_DIR` when it is set, and
/// are attached to the result bundle either way. (xcodebuild hands both over
/// from `TEST_RUNNER_ATA_FIXTURES` and `TEST_RUNNER_ATA_SNAPSHOT_DIR`.)
final class AtaSnapshotTests: XCTestCase {
    /// The same names as `Snapshots.Screen` in the app.
    private static let screens = [
        "record-idle", "record-recording", "meetings", "meeting-notes", "meeting-transcript",
        "people", "insights", "settings", "onboarding",
    ]

    override func setUpWithError() throws {
        // One screen that doesn't come up must not cost the rest of the set.
        continueAfterFailure = true
    }

    @MainActor
    func testLightScreens() throws {
        try photograph(appearance: "light")
    }

    @MainActor
    func testDarkScreens() throws {
        try photograph(appearance: "dark")
    }

    @MainActor
    private func photograph(appearance: String) throws {
        let env = ProcessInfo.processInfo.environment
        let fixtures = try XCTUnwrap(env["ATA_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 },
                                     "Set TEST_RUNNER_ATA_FIXTURES to the folder ios/snapshots.sh makes")
        let output = env["ATA_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }

        for screen in Self.screens {
            let name = "iphone-\(screen)-\(appearance)"
            let folder = try freshCopy(of: URL(fileURLWithPath: fixtures, isDirectory: true), named: name)

            let app = XCUIApplication()
            app.launchArguments = [
                "-AtaSnapshots", screen,
                "-AtaSnapshotAppearance", appearance,
                // Argument-domain preferences: they win over anything stored, for this launch only.
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-myName", "Alex", "-language", "auto", "-onboarded", "YES",
                "-keepAudio", "YES", "-recogniseVoices", "YES", "-summarize", "YES",
            ]
            app.launchEnvironment = [
                "ATA_MEETINGS_DIR": folder.appendingPathComponent("meetings").path,
                "ATA_SUPPORT_DIR": folder.appendingPathComponent("support").path,
            ]
            app.launch()

            if !ready(screen, in: app).waitForExistence(timeout: 30) {
                XCTFail("\(name): the screen did not come up")
            }
            if screen == "meeting-transcript" {
                let tab = app.segmentedControls.buttons["Transcript"]
                if tab.waitForExistence(timeout: 10) {
                    tab.tap()
                } else {
                    XCTFail("\(name): no Transcript tab")
                }
            }
            // Let the tab switch and the first layout pass settle.
            Thread.sleep(forTimeInterval: 1.5)

            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            if let output {
                do {
                    try shot.pngRepresentation.write(to: output.appendingPathComponent("\(name).png"))
                } catch {
                    XCTFail("\(name): \(error.localizedDescription)")
                }
            }
            app.terminate()
        }
    }

    /// Something only that screen has, so a launch that went elsewhere fails.
    @MainActor
    private func ready(_ screen: String, in app: XCUIApplication) -> XCUIElement {
        switch screen {
        case "record-idle": return app.buttons["Record a conversation"]
        case "record-recording": return app.buttons["Stop recording"]
        case "meetings": return app.navigationBars["Meetings"]
        // Not any segmented control: Record has one too.
        case "meeting-notes", "meeting-transcript": return app.segmentedControls.buttons["Transcript"]
        case "people": return app.navigationBars["People"]
        case "insights": return app.navigationBars["Insights"]
        case "settings": return app.navigationBars["Settings"]
        case "onboarding": return app.staticTexts["Welcome to Ata"]
        default: return app.windows.firstMatch
        }
    }

    /// A copy of the fixtures for one launch, next to the originals: on a
    /// simulator the app reads the Mac's file system directly.
    private func freshCopy(of fixtures: URL, named name: String) throws -> URL {
        let fm = FileManager.default
        let runs = fixtures.deletingLastPathComponent().appendingPathComponent("runs", isDirectory: true)
        let folder = runs.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: runs, withIntermediateDirectories: true)
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        try fm.copyItem(at: fixtures, to: folder)
        return folder
    }
}
