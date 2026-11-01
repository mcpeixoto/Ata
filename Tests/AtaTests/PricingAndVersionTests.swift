@testable import Ata
import XCTest

final class UpdaterVersionTests: XCTestCase {
    func testTagsLoseTheirPrefix() {
        XCTAssertEqual(Updater.normalize("v2.2.0"), "2.2.0")
        XCTAssertEqual(Updater.normalize("2.2.0"), "2.2.0")
    }

    func testVersionsCompareNumerically() {
        XCTAssertTrue(Updater.isNewer("2.10.0", than: "2.9.0"))
        XCTAssertTrue(Updater.isNewer("2.2.0", than: "2.1.9"))
        XCTAssertTrue(Updater.isNewer("3", than: "2.99"))
        XCTAssertFalse(Updater.isNewer("2.2.0", than: "2.2.0"))
        XCTAssertFalse(Updater.isNewer("2.2", than: "2.2.0"))
        XCTAssertFalse(Updater.isNewer("2.1.0", than: "2.2.0"))
    }
}
