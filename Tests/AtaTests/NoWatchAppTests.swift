import XCTest

/// Ata has no Apple Watch app: nothing builds one, embeds one or talks to one.
final class NoWatchAppTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AtaTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    func testTheIPhoneProjectHasNoWatchTarget() throws {
        let project = try String(contentsOf: Self.repo.appending(path: "ios/project.yml"), encoding: .utf8)
        XCTAssertFalse(project.contains("watchOS"), "no watchOS target")
        XCTAssertFalse(project.contains("AtaWatch"), "nothing embeds a Watch app")
        let export = try String(contentsOf: Self.repo.appending(path: "ios/ExportOptions.plist"), encoding: .utf8)
        XCTAssertFalse(export.contains("watchkitapp"), "no Watch profile to export with")
    }

    func testNoSourceTalksToAWatch() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.repo.appending(path: "Sources/AtaWatch").path))
        var offenders: [String] = []
        let walker = FileManager.default.enumerator(at: Self.repo.appending(path: "Sources"), includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("import WatchConnectivity") || text.contains("os(watchOS)") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
