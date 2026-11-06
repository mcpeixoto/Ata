@testable import Ata
import XCTest

/// The iPhone's switch turned on before iCloud Drive was: Ata waits, and turns
/// sync on by itself the moment iCloud answers, and never otherwise.
final class ICloudWaitTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    func testTurnsOnOnlyWhenWaitingAndICloudHasAnswered() {
        XCTAssertTrue(CloudSync.turnsOnNow(waiting: true, isOn: false, status: .available))
        XCTAssertFalse(CloudSync.turnsOnNow(waiting: false, isOn: false, status: .available), "never asked for")
        XCTAssertFalse(CloudSync.turnsOnNow(waiting: true, isOn: true, status: .available), "already on")
        for status in [CloudLibrary.Status.checking, .signedOut, .notOnThisMac] {
            XCTAssertFalse(CloudSync.turnsOnNow(waiting: true, isOn: false, status: status), "\(status): iCloud isn't there yet")
        }
    }

    func testTheWaitIsRememberedUnderItsOwnKey() {
        XCTAssertEqual(Pref.iCloudWanted, "iCloudWanted")
        XCTAssertNotEqual(Pref.iCloudWanted, Pref.iCloudSync, "waiting is not the same as being on")
    }

    /// The help sheet's sentences are in both tables, so the Portuguese iPhone
    /// never shows English steps.
    func testTheHelpIsTranslated() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pt = try XCTUnwrap(NSDictionary(contentsOf: repo.appending(path: "Resources/pt.lproj/Localizable.strings")) as? [String: String])
        for key in ["Turn on iCloud Drive for Ata", "Open Settings and tap your name at the top.",
                    "Tap iCloud, then iCloud Drive.", "Turn on Sync this iPhone.",
                    "Turn on Ata in the list of apps below it.",
                    "Waiting for iCloud Drive. Turn it on for Ata in Settings, and this finishes by itself."] {
            let translated = try XCTUnwrap(pt[key], key)
            XCTAssertNotEqual(translated, key, key)
        }
    }
}
