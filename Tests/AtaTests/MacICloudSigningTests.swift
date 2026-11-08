@testable import Ata
import XCTest

/// The Mac release carries Ata's iCloud entitlements. Without them iCloud Drive
/// on the Mac never syncs the container ("SYNC DISABLED (app not installed)"),
/// however much the iPhone uploads: the bug behind sync that never worked.
final class MacICloudSigningTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AtaTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.repo.appending(path: path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], path)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repo.appending(path: path), encoding: .utf8)
    }

    func testTheICloudEntitlementsNameAtasContainer() throws {
        let iCloud = try plist("Resources/Ata-iCloud.entitlements")
        XCTAssertEqual(iCloud["com.apple.developer.ubiquity-container-identifiers"] as? [String], [CloudLibrary.containerID])
        XCTAssertEqual(iCloud["com.apple.developer.icloud-container-identifiers"] as? [String], [CloudLibrary.containerID])
        XCTAssertEqual(iCloud["com.apple.developer.icloud-services"] as? [String], ["CloudDocuments"])
        XCTAssertEqual(iCloud["com.apple.developer.icloud-container-environment"] as? String, "Production")
        XCTAssertEqual(iCloud["com.apple.application-identifier"] as? String, "H874DPF6H5.ai.interactive.ata")
        XCTAssertEqual(iCloud["com.apple.developer.ubiquity-kvstore-identifier"] as? String,
                       "H874DPF6H5.ai.interactive.ata", "the same settings store as the iPhone")
    }

    /// Restricted entitlements without a profile get an app killed at launch, so
    /// the file every build signs with must never carry them.
    func testTheBaseEntitlementsStayUnrestricted() throws {
        let base = try plist("Resources/Ata.entitlements")
        for key in base.keys {
            XCTAssertFalse(key.hasPrefix("com.apple.developer."), key)
            XCTAssertNotEqual(key, "com.apple.application-identifier")
        }
    }

    func testAReleaseRefusesToShipWithoutICloud() throws {
        let build = try text("scripts/build-app.sh")
        XCTAssertTrue(build.contains("Resources/Ata-iCloud.entitlements"))
        XCTAssertTrue(build.contains("embedded.provisionprofile"))
        XCTAssertTrue(build.contains("ATA_REQUIRE_ICLOUD"))
        let release = try text("scripts/release-local.sh")
        XCTAssertTrue(release.contains("ATA_REQUIRE_ICLOUD=1 ./scripts/build-app.sh"))
        XCTAssertTrue(release.contains("scripts/mac-profile.py"))
    }
}
