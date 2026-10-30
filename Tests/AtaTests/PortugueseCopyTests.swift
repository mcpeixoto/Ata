import XCTest

/// The Portuguese tables are European Portuguese, "tu" form, and Ata is "a Ata".
/// Every one of these slipped in once, a string at a time, and none of them is
/// visible in an English review or a screenshot, so the tables themselves are
/// read here.
final class PortugueseCopyTests: XCTestCase {
    private static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent()   // AtaTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    /// Every Portuguese .strings table: the apps', the iPhone's Info.plist and
    /// extension texts, and the Watch's. Keyed "file: English key".
    private static func portuguese() throws -> [String: String] {
        let paths = ["Resources", "Sources/AtaWatch"]
        var out: [String: String] = [:]
        for base in paths {
            let dir = repo.appending(path: base)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker
            where url.pathExtension == "strings" && url.deletingLastPathComponent().lastPathComponent == "pt.lproj" {
                let data = try Data(contentsOf: url)
                let table = try XCTUnwrap(try PropertyListSerialization
                    .propertyList(from: data, format: nil) as? [String: String], url.path)
                for (key, value) in table {
                    out["\(url.lastPathComponent): \(key)"] = value
                }
            }
        }
        return out
    }

    private func offenders(_ pattern: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return try Self.portuguese().compactMap { key, value in
            let range = NSRange(value.startIndex..., in: value)
            return regex.firstMatch(in: value, range: range) == nil ? nil : "\(key) → \(value)"
        }.sorted()
    }

    func testThereArePortugueseTablesToRead() throws {
        XCTAssertGreaterThan(try Self.portuguese().count, 500)
    }

    /// "a Ata", never "o Ata".
    func testAtaIsFeminine() throws {
        XCTAssertEqual(try offenders(#"\b([Oo]|[Dd]o|[Nn]o|[Aa]o|[Pp]elo) Ata\b"#), [])
    }

    /// One word for a meeting, and it is Portuguese.
    func testAMeetingIsAReuniao() throws {
        XCTAssertEqual(try offenders(#"(?i)\bmeetings?\b"#), [])
    }

    /// Portugal's App Store words, not Brazil's.
    func testSubscriptionsUsePortugalsWords() throws {
        XCTAssertEqual(try offenders(#"(?i)\bassinatura|\bassinar\b"#), [])
    }

    /// "para" lost its accent in the 1990 spelling reform.
    func testParaHasNoAccent() throws {
        XCTAssertEqual(try offenders(#"(?i)\bpára\b"#), [])
    }
}
