import XCTest

final class FolderNamesTests: XCTestCase {
    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    func testMatchesTheMacFolderNames() {
        let started = date("2026-10-23 14:02:05")
        XCTAssertEqual(FolderNames.name(startedAt: started, app: nil), "2026-10-23 14.02.05")
        XCTAssertEqual(FolderNames.name(startedAt: started, app: "Call"), "2026-10-23 14.02.05 Call")
    }

    func testAnEmptyAppIsNoApp() {
        XCTAssertEqual(FolderNames.name(startedAt: date("2026-01-02 03:04:05"), app: ""), "2026-01-02 03.04.05")
    }

    func testAppLabelsNeverMakeAPath() {
        let name = FolderNames.name(startedAt: date("2026-01-02 03:04:05"), app: "a/b:c")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testUniqueKeepsAFreeName() {
        XCTAssertEqual(FolderNames.unique("x", existing: ["y"]), "x")
    }

    func testUniqueNumbersATakenName() {
        XCTAssertEqual(FolderNames.unique("x", existing: ["x"]), "x 2")
        XCTAssertEqual(FolderNames.unique("x", existing: ["x", "x 2", "x 3"]), "x 4")
    }
}
