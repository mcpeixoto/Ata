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
/// row hittable, or is the tab bar sitting on top of it? Measured on iOS 26.5: it
/// is hittable, the list is fine, and the row in the screenshots is the tab bar
/// being translucent.
///
/// Scrolling is driven off the rows themselves. A `List` row wrapping a
/// `NavigationLink` reports an *empty* label on its cell — the text lives on the
/// button inside — so a signature built from `cells.label` reads the same at every
/// scroll position. Reading "have we reached the end?" that way stops after a
/// single swipe and then asks about whichever row happens to be under the tab bar,
/// which is how this test spent its first weeks failing against a healthy list.
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
        // The rows arrive after the list itself. Waiting for the first one matters:
        // an empty list and a list that has stopped scrolling both look like "no
        // change", so without this the loop below can call an unpopulated list
        // "the end" and then ask its question about nothing.
        XCTAssertTrue(list.buttons.firstMatch.waitForExistence(timeout: 30),
                      "the fixtures should give the list some rows")

        // To the end of the list. The signature is every row's name and where it
        // sits, so it stops changing only once the list itself has stopped moving.
        // Bounded, because more swipes at the end prove nothing.
        var previous: String?
        var reachedTheEnd = false
        for _ in 0..<20 {
            let signature = rowSignature(of: list)
            XCTAssertFalse(signature.isEmpty, "the list lost its rows mid-scroll")
            if signature == previous {
                reachedTheEnd = true
                break
            }
            previous = signature
            list.swipeUp()
        }
        XCTAssertTrue(reachedTheEnd, "the list was still moving after 20 swipes, so this never reached the end")

        let rows = list.buttons.allElementsBoundByIndex
        let last = try XCTUnwrap(rows.last, "the fixtures should give the list some rows")

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

    /// Every row's name and position as one string: the same only when the list
    /// has not moved between two looks at it.
    @MainActor
    private func rowSignature(of list: XCUIElement) -> String {
        list.buttons.allElementsBoundByIndex
            .map { "\($0.label)@\(Int($0.frame.origin.y.rounded()))" }
            .joined(separator: "|")
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
