import XCTest

/// Ata is source-available under PolyForm Noncommercial, and everything that
/// names the licence says the same.
final class LicenseTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AtaTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    private func read(_ path: String) throws -> String {
        try String(contentsOf: Self.repo.appending(path: path), encoding: .utf8)
    }

    func testTheLicenceIsPolyFormNoncommercial() throws {
        let licence = try read("LICENSE")
        XCTAssertTrue(licence.hasPrefix("# PolyForm Noncommercial License 1.0.0"))
        XCTAssertTrue(licence.contains("Required Notice: Copyright (c) 2026 Miguel Peixoto"))
    }

    func testNothingStillSaysMIT() throws {
        for path in ["Resources/Info.plist", "Resources/iOS/Info.plist"] {
            let plist = try read(path)
            XCTAssertTrue(plist.contains("PolyForm Noncommercial"), path)
            XCTAssertFalse(plist.contains("MIT"), path)
        }
        XCTAssertFalse(try read("README.md").contains("license-MIT"), "the README badge")
        XCTAssertFalse(try read("Sources/Ata/Snapshots.swift").contains("\"Open source\""), "the banner")
    }
}
