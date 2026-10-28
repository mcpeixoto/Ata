import XCTest
@testable import Ata

/// Asking for the calendar, and what to do when macOS does not ask.
final class CalendarAccessTests: XCTestCase {
    func testAGrantNeedsNothingFurther() {
        XCTAssertEqual(CalendarAccess.nextStep(before: .notDetermined, after: .authorized), .nothing)
    }

    /// The user just said no in the dialog. Throwing System Settings at them a
    /// second later would be nagging, not helping.
    func testARefusalInTheDialogDoesNotOpenSettings() {
        XCTAssertEqual(CalendarAccess.nextStep(before: .notDetermined, after: .denied), .nothing)
    }

    /// The case this exists for: the request came back with the status
    /// unchanged, which means macOS never put anything on screen. The button
    /// must not look dead.
    func testASilentRequestOpensSettings() {
        XCTAssertEqual(CalendarAccess.nextStep(before: .notDetermined, after: .notDetermined), .openSettings)
        XCTAssertTrue(CalendarAccess.wasSilent(before: .notDetermined, after: .notDetermined))
    }

    /// Already answered in an earlier run: macOS will not ask twice, so the
    /// pane is the only route.
    func testAnEarlierRefusalGoesStraightToSettings() {
        XCTAssertEqual(CalendarAccess.nextStep(before: .denied, after: .denied), .openSettings)
        XCTAssertEqual(CalendarAccess.nextStep(before: .writeOnly, after: .writeOnly), .openSettings)
        XCTAssertFalse(CalendarAccess.wasSilent(before: .denied, after: .denied))
    }

    /// The entitlement the hardened runtime needs before macOS will show the
    /// calendar dialog at all. Without it `tccd` logs "Prompting policy for
    /// hardened runtime … requires entitlement
    /// com.apple.security.personal-information.calendars" and refuses the
    /// request, which is what shipped in 2.11.0 — a Permitir button that did
    /// nothing. Nothing in the app can notice its absence, so the file itself
    /// is what gets checked.
    func testTheAppAsksForTheCalendarEntitlement() throws {
        let repo = URL(filePath: #filePath)
            .deletingLastPathComponent()   // AtaTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
        let url = repo.appending(path: "Resources/Ata.entitlements")
        let plist = try Data(contentsOf: url)
        let keys = try XCTUnwrap(try PropertyListSerialization
            .propertyList(from: plist, format: nil) as? [String: Any])
        XCTAssertEqual(keys["com.apple.security.personal-information.calendars"] as? Bool, true)
        // The microphone's counterpart, for the same reason.
        XCTAssertEqual(keys["com.apple.security.device.audio-input"] as? Bool, true)
    }
}
