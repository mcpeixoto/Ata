import XCTest
@testable import Ata

/// The settings split: pane screenshot names, and when a footnote is long
/// enough to sit behind the info button.
final class SettingsSplitTests: XCTestCase {
    func testTheWindowIsTheSettingsSplitSize() {
        XCTAssertEqual(SettingsView.width, 700)
        XCTAssertEqual(SettingsView.height, 520)
    }

    func testGeneralKeepsTheOldSnapshotName() {
        XCTAssertEqual(SettingsPane.general.snapshotName, "settings")
        let names = SettingsPane.allCases.map(\.snapshotName)
        XCTAssertEqual(names.count, 8)
        XCTAssertEqual(Set(names).count, 8, "each pane needs its own screenshot")
        XCTAssertEqual(SettingsPane.allCases.filter { $0.snapshotName == "settings" }, [.general])
    }

    func testAShortFootnoteStaysOnTheForm() {
        let text = "Ata needs permission to read your calendar."
        XCTAssertEqual(SettingsNoteLayout.lineCount(text, width: 460), 1)
        XCTAssertFalse(SettingsNoteLayout.collapses(text, width: 460))
    }

    func testAParagraphCollapsesBehindTheInfoButton() {
        let text = "A meeting from one of these calendars gets its category. Otherwise Ata goes by the app: Zoom, Teams or Slack is work, FaceTime or WhatsApp is personal. You can change it in the meeting."
        XCTAssertGreaterThan(SettingsNoteLayout.lineCount(text, width: 460), 2)
        XCTAssertTrue(SettingsNoteLayout.collapses(text, width: 460))
    }

    func testTwoLinesIsTheBoundary() {
        let width: CGFloat = 320
        var words = ["Ata"]
        while SettingsNoteLayout.lineCount(words.joined(separator: " "), width: width) < 2 {
            words.append("notes")
        }
        let two = words.joined(separator: " ")
        XCTAssertEqual(SettingsNoteLayout.lineCount(two, width: width), 2)
        XCTAssertFalse(SettingsNoteLayout.collapses(two, width: width))
        let three = two + " " + String(repeating: "notes ", count: 40)
        XCTAssertGreaterThan(SettingsNoteLayout.lineCount(three, width: width), 2)
        XCTAssertTrue(SettingsNoteLayout.collapses(three, width: width))
    }

    func testAnUnmeasuredColumnDoesNotCollapse() {
        XCTAssertFalse(SettingsNoteLayout.collapses(String(repeating: "word ", count: 80), width: 0))
    }
}
