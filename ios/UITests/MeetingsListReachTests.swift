import XCTest

/// Can you actually reach the last meeting in the list?
///
/// The screenshots in `iphone-meetings-*.png` show a row running underneath the
/// floating tab bar, which looks like a missing bottom inset. It is also exactly
/// what a correct, translucent iOS 26 tab bar looks like at the top of a scroll:
/// content passes beneath it and the scroll view's own inset lets you bring the
/// last row clear. A still frame cannot tell those two apart — only scrolling can.
///
/// So this scrolls to the end and asks the one question that matters: is the last
/// row hittable, or is the tab bar sitting on top of it?
final class MeetingsListReachTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTheLastMeetingClearsTheTabBar() throws {
        let env = ProcessInfo.processInfo.environment
        let fixtures = try XCTUnwrap(env["ATA_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 },
                                     "Set TEST_RUNNER_ATA_FIXTURES to the folder ios/snapshots.sh makes")
        let folder = try freshCopy(of: URL(fileURLWithPath: fixtures, isDirectory: true),
                                   named: "meetings-reach")

        let app = XCUIApplication()
        app.launchArguments = [
            "-AtaSnapshots", "meetings",
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

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the meetings list should come up")

        // To the end of the list. Bounded, because a swipe that changes nothing
        // means we are already there and more swipes prove nothing.
        var previous = ""
        for _ in 0..<8 {
            let cells = list.cells.allElementsBoundByIndex
            let signature = cells.map(\.label).joined(separator: "|")
            if signature == previous { break }
            previous = signature
            list.swipeUp()
        }

        let cells = list.cells.allElementsBoundByIndex
        let last = try XCTUnwrap(cells.last, "the fixtures should give the list some rows")

        // The question. A row the tab bar covers is not hittable, however much
        // of it is drawn on screen.
        XCTAssertTrue(
            last.isHittable,
            """
            The last meeting ("\(last.label)") cannot be tapped once scrolled to the end: \
            frame \(last.frame), window \(app.windows.firstMatch.frame). \
            That is the missing bottom inset behind the floating tab bar.
            """
        )

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "meetings-scrolled-to-end"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Each launch gets its own copy, so nothing carries over between runs.
    private func freshCopy(of fixtures: URL, named: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-\(named)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixtures, to: destination)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        return destination
    }
}
