import XCTest

/// Ata is open source under the Apache License 2.0, and everything that names
/// the licence says the same.
final class LicenseTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AtaTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.repo.appending(path: path), encoding: .utf8)
    }

    func testTheLicenceIsApache2() throws {
        let licence = try read("LICENSE")
        XCTAssertTrue(licence.contains("Apache License"))
        XCTAssertTrue(licence.contains("Version 2.0, January 2004"))
        XCTAssertTrue(licence.contains("http://www.apache.org/licenses/"))
    }

    func testTheNoticeNamesTheHolderAndTheLicence() throws {
        let notice = try read("NOTICE")
        XCTAssertTrue(notice.contains("Copyright 2026 Miguel Peixoto"))
        XCTAssertTrue(notice.contains("Apache License, Version 2.0"))
    }

    func testNothingStillClaimsAnOlderLicence() throws {
        for path in ["Resources/Info.plist", "Resources/iOS/Info.plist"] {
            let plist = try read(path)
            XCTAssertTrue(plist.contains("Apache License 2.0"), path)
            XCTAssertFalse(plist.contains("PolyForm"), path)
            XCTAssertFalse(plist.contains("MIT"), path)
        }
        let readme = try read("README.md")
        XCTAssertFalse(readme.contains("license-MIT"), "the README badge")
        XCTAssertFalse(readme.contains("PolyForm"), "the README")
    }
}
