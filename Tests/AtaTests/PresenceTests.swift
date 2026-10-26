@testable import Ata
import AppKit
import XCTest

/// Reaching Ata when the menu bar has no room for it.
///
/// macOS hides the menu bar icons that don't fit and gives an app no say in the
/// order, so an icon that cannot be reached cannot be fixed from inside the
/// app. These cover the two ways out — being in the Dock, and a global shortcut
/// — and the rule that stops the settings leaving Ata with no way in at all.
final class PresenceTests: XCTestCase {
    @MainActor
    func testTheMenuBarIconIsOnlyHiddenWhenTheDockIconReplacesIt() {
        XCTAssertTrue(Presence.menuBarIconShows(dock: false, menuBar: true))
        XCTAssertTrue(Presence.menuBarIconShows(dock: false, menuBar: false),
                      "with no Dock icon the menu bar icon is the only way in, whatever the setting says")
        XCTAssertTrue(Presence.menuBarIconShows(dock: true, menuBar: true))
        XCTAssertFalse(Presence.menuBarIconShows(dock: true, menuBar: false))
    }

    @MainActor
    func testTurningTheDockIconOffBringsTheMenuBarIconBack() {
        let dock = Pref.d.bool(forKey: Pref.dockIcon)
        let bar = Pref.d.bool(forKey: Pref.menuBarIcon)
        defer {
            Pref.d.set(dock, forKey: Pref.dockIcon)
            Pref.d.set(bar, forKey: Pref.menuBarIcon)
        }

        Pref.d.set(true, forKey: Pref.dockIcon)
        Pref.d.set(false, forKey: Pref.menuBarIcon)
        Presence.setDockIcon(false)

        XCTAssertTrue(Pref.d.bool(forKey: Pref.menuBarIcon), "otherwise Ata would be running with no icon anywhere")
        XCTAssertTrue(Presence.showsMenuBarIcon)
    }
}

final class ShortcutTests: XCTestCase {
    func testAShortcutSurvivesBeingStoredAndReadBack() {
        let shortcut = Shortcut(keyCode: 15, modifiers: [.command, .option])
        let read = Shortcut(shortcut.stored)
        XCTAssertEqual(read, shortcut)
        XCTAssertEqual(read?.keyCode, 15)
    }

    func testNothingIsReadFromAnEmptyOrBrokenSetting() {
        XCTAssertNil(Shortcut(""))
        XCTAssertNil(Shortcut("15"))
        XCTAssertNil(Shortcut("R,command"))
        XCTAssertNil(Shortcut("15,1048576,extra"))
    }

    /// Only the four modifiers the system lets an app claim are kept; caps lock
    /// and fn would never be matched and must not change what is stored.
    func testOnlyTheUsualModifiersAreKept() {
        let shortcut = Shortcut(keyCode: 15, modifiers: [.command, .capsLock, .function])
        XCTAssertEqual(shortcut.modifiers, .command)
    }

    func testAShortcutNeedsARealModifier() {
        XCTAssertTrue(Shortcut(keyCode: 15, modifiers: [.command]).isUsable)
        XCTAssertTrue(Shortcut(keyCode: 15, modifiers: [.control, .shift]).isUsable)
        // A bare key, or shift and a key, would swallow that keystroke everywhere.
        XCTAssertFalse(Shortcut(keyCode: 15, modifiers: []).isUsable)
        XCTAssertFalse(Shortcut(keyCode: 15, modifiers: [.shift]).isUsable)
    }

    func testAShortcutReadsTheWayTheMenuBarWritesIt() {
        XCTAssertEqual(Shortcut(keyCode: 15, modifiers: [.command, .option]).display, "⌥⌘R")
        XCTAssertEqual(Shortcut(keyCode: 15, modifiers: [.control, .shift, .command]).display, "⌃⇧⌘R")
        XCTAssertEqual(Shortcut(keyCode: 49, modifiers: [.command]).display, "⌘Space")
        XCTAssertEqual(Shortcut(keyCode: 122, modifiers: [.option]).display, "⌥F1")
    }

    func testAKeyWithNoNameDoesNotRenderAsEmpty() {
        XCTAssertEqual(Shortcut.name(of: 9_999), "?")
    }
}

/// Asking again whether there is an update.
///
/// The answer "you are on the latest version" used to replace the button that
/// asked the question, so once Ata had said it, it went on saying it for the
/// rest of the session — a release published an hour later could not be found
/// without quitting the app.
final class UpdateCheckTests: XCTestCase {
    @MainActor
    func testBeingUpToDateNeverStopsYouAskingAgain() {
        XCTAssertTrue(Updater.canCheck(in: .upToDate))
        XCTAssertTrue(Updater.canCheck(in: .idle))
        XCTAssertTrue(Updater.canCheck(in: .failed("no network")))
        XCTAssertTrue(Updater.canCheck(in: .available(version: "9.9.9", notes: "")))
    }

    /// A check already running, or an install under way, is a real reason to wait.
    @MainActor
    func testWorkAlreadyUnderWayIsLeftAlone() {
        XCTAssertFalse(Updater.canCheck(in: .checking))
        XCTAssertFalse(Updater.canCheck(in: .downloading(0.4)))
        XCTAssertFalse(Updater.canCheck(in: .installing))
    }
}
