@testable import Ata
import AppKit
import XCTest

/// Closing, quitting and opening: what a person sees depends on these rules.
final class MenuBarBehaviourTests: XCTestCase {
    func testCommandQClosesWindowsAndNothingElseDoes() {
        XCTAssertTrue(QuitKey.closesWindows(characters: "q", modifiers: .command))
        XCTAssertTrue(QuitKey.closesWindows(characters: "Q", modifiers: [.command, .capsLock]))
        XCTAssertFalse(QuitKey.closesWindows(characters: "q", modifiers: [.command, .shift]))
        XCTAssertFalse(QuitKey.closesWindows(characters: "q", modifiers: [.command, .option]))
        XCTAssertFalse(QuitKey.closesWindows(characters: "q", modifiers: []), "typing the letter q in your notes")
        XCTAssertFalse(QuitKey.closesWindows(characters: "w", modifiers: .command))
        XCTAssertFalse(QuitKey.closesWindows(characters: nil, modifiers: .command))
    }

    func testCommandWClosesOneWindow() {
        XCTAssertTrue(QuitKey.closesOneWindow(characters: "w", modifiers: .command))
        XCTAssertFalse(QuitKey.closesOneWindow(characters: "w", modifiers: [.command, .shift]))
        XCTAssertFalse(QuitKey.closesOneWindow(characters: "q", modifiers: .command))
    }

    func testQuitOnlyAsksWhenItWouldInterruptSomething() {
        XCTAssertNil(QuitWarning.needed(recording: false, transcribing: false))
        XCTAssertEqual(QuitWarning.needed(recording: false, transcribing: true), .transcribing)
        XCTAssertEqual(QuitWarning.needed(recording: true, transcribing: true), .recording, "the bigger of the two")
    }

    func testOpeningAtaByHandShowsAWindow() {
        XCTAssertTrue(LaunchWindow.shows(arguments: [], loginItemEvent: false, loginItemOn: true, uptime: 7_200))
        XCTAssertTrue(LaunchWindow.shows(arguments: [], loginItemEvent: false, loginItemOn: false, uptime: 10),
                      "no login item, so this launch was on purpose")
    }

    func testStartingUpAndRestartingStayQuiet() {
        XCTAssertFalse(LaunchWindow.shows(arguments: [], loginItemEvent: true, loginItemOn: true, uptime: 7_200))
        XCTAssertFalse(LaunchWindow.shows(arguments: [], loginItemEvent: false, loginItemOn: true, uptime: 30))
        XCTAssertFalse(LaunchWindow.shows(arguments: ["Ata", LaunchWindow.quietArgument],
                                          loginItemEvent: false, loginItemOn: false, uptime: 7_200))
    }

    func testRecordingIsVisibleAndHasAShortcutOutOfTheBox() throws {
        XCTAssertEqual(Pref.platformDefaults[Pref.menuIconTint] as? String, MenuIcon.Tint.red.rawValue)
        let stored = try XCTUnwrap(Pref.platformDefaults[Pref.recordShortcut] as? String)
        let shortcut = try XCTUnwrap(Shortcut(stored))
        XCTAssertTrue(shortcut.isUsable)
        XCTAssertEqual(shortcut.display, "⌃⌥⌘R")
        XCTAssertEqual(Pref.platformDefaults[Pref.dockIcon] as? Bool, false)
    }

    /// Turning the shortcut off stores an empty value; removing it instead would
    /// bring the default back at the next launch.
    func testAShortcutTurnedOffStaysOff() {
        XCTAssertNil(Shortcut(""))
    }
}
