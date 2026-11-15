import XCTest

/// A ratchet on the shared views (drawn on the Mac and the iPhone): literal font
/// sizes ignore Dynamic Type on the iPhone and drift from `AtaType`, so their
/// number may only go down. Lower a ceiling when a file loses one; never raise it.
final class DesignSystemTests: XCTestCase {
    private static let sources = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/Ata")

    private static let literalFontCeilings: [String: Int] = [
        "MeetingView.swift": 3,
        "PeopleView.swift": 1,
        "InsightsView.swift": 1,
        "Components.swift": 3,
    ]

    func testSharedViewsAddNoLiteralFontSizes() throws {
        for (file, ceiling) in Self.literalFontCeilings {
            let text = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
            let count = text.components(separatedBy: ".font(.system(size:").count - 1
            XCTAssertLessThanOrEqual(count, ceiling,
                "\(file) has \(count) literal font sizes; use AtaType (ScaledType.swift) instead")
        }
    }

    func testSharedViewsUseRadiusTokensForNewShapes() throws {
        // Every radius in a shared view is a token, or a literal with a comment saying why.
        for file in Self.literalFontCeilings.keys {
            let lines = try String(contentsOf: Self.sources.appending(path: file), encoding: .utf8)
                .components(separatedBy: .newlines)
            let bare = lines.filter { line in
                guard let range = line.range(of: "cornerRadius: ") else { return false }
                let after = line[range.upperBound...]
                return after.first?.isNumber == true && !line.contains("//")
            }
            XCTAssertLessThanOrEqual(bare.count, Self.radiusCeilings[file] ?? 0,
                "\(file): use Radius.small/medium/large, or say why next to the literal:\n" + bare.joined(separator: "\n"))
        }
    }

    /// Literal radii left after the 3.8.0 redesign. Only ever lower these.
    private static let radiusCeilings: [String: Int] = [
        "MeetingView.swift": 0,
        "PeopleView.swift": 1,
        "InsightsView.swift": 0,
        "Components.swift": 2,
    ]
}
