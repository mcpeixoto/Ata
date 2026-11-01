@testable import Ata
import XCTest

/// The summary is drawn line by line so list items hang-indent.
final class SummaryLinesTests: XCTestCase {
    private func plain(_ line: MeetingNotes.Line) -> String { String(line.text.characters) }

    func testBulletsKeepTheirMarkerApartFromTheText() {
        let lines = MeetingNotes.lines("**Next steps**\n- Alex sends the deck to Sam by Friday\n* Sam books the room\n• Tell support")
        XCTAssertEqual(lines.map(\.marker), [nil, "•", "•", "•"])
        XCTAssertEqual(lines.map(plain), ["Next steps", "Alex sends the deck to Sam by Friday",
                                          "Sam books the room", "Tell support"])
        XCTAssertEqual(lines.map(\.level), [0, 0, 0, 0])
    }

    func testNestedAndNumberedItems() {
        let lines = MeetingNotes.lines("1. Ship\n  - with notes\n12. Review\n2026 was fine.")
        XCTAssertEqual(lines.map(\.marker), ["1.", "•", "12.", nil])
        XCTAssertEqual(lines.map(\.level), [0, 1, 0, 0])
        XCTAssertEqual(lines.map(plain), ["Ship", "with notes", "Review", "2026 was fine."])
    }

    func testBlankLinesStayAndInlineMarkdownIsRead() {
        let lines = MeetingNotes.lines("**Decisions**\n\n- Ship **on Friday**")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].text.characters.isEmpty)
        XCTAssertNil(lines[1].marker)
        XCTAssertEqual(plain(lines[2]), "Ship on Friday")
    }
}

/// "Who talks" and "Where" in Insights carry their numbers.
final class InsightsLabelTests: XCTestCase {
    func testTalkPercentsAddUpToAHundred() {
        var i = Insights()
        XCTAssertNil(i.talkPercents?.mine, "nothing to show before anyone spoke")
        i.mySpeech = 41.6
        i.othersSpeech = 58.4
        XCTAssertEqual(i.talkPercents?.mine, 42)
        XCTAssertEqual(i.talkPercents?.others, 58)
        i.mySpeech = 1
        i.othersSpeech = 2
        XCTAssertEqual((i.talkPercents?.mine ?? 0) + (i.talkPercents?.others ?? 0), 100)
    }

    func testWhereBarsSayHowLong() {
        XCTAssertEqual(Insights.duration(minutes: 44.6), "45 min")
        XCTAssertEqual(Insights.duration(minutes: 125), "2h 05m")
    }
}

/// One word for marking a moment, on the Mac, the iPhone, the Watch, the Live
/// Activity and Siri: "Mark", "Marcar" in Portuguese. The iPhone once said
/// "Bookmark this moment" and "Bookmarks: 2" next to the Mac's "Mark this moment".
final class MarkTermTests: XCTestCase {
    private static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent()   // AtaTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo

    private func table(_ path: String) throws -> [String: String] {
        let data = try Data(contentsOf: Self.repo.appending(path: path))
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    func testNoTableSaysBookmark() throws {
        for path in ["Resources/en.lproj/Localizable.strings", "Resources/pt.lproj/Localizable.strings",
                     "Resources/iOS/en.lproj/AppShortcuts.strings", "Resources/iOS/pt.lproj/AppShortcuts.strings"] {
            let offenders = try table(path).filter { key, value in
                key.localizedCaseInsensitiveContains("bookmark") || value.localizedCaseInsensitiveContains("bookmark")
                    || value.localizedCaseInsensitiveContains("marcador")
            }
            XCTAssertEqual(offenders, [:], path)
        }
    }

    func testTheSameWordsEverywhere() throws {
        let en = try table("Resources/en.lproj/Localizable.strings")
        let pt = try table("Resources/pt.lproj/Localizable.strings")
        let siriEN = try table("Resources/iOS/en.lproj/AppShortcuts.strings")
        let siriPT = try table("Resources/iOS/pt.lproj/AppShortcuts.strings")

        XCTAssertEqual(pt["Mark this moment"], "Marcar este momento")
        XCTAssertEqual(pt["Mark"], "Marcar")
        XCTAssertTrue(pt["Mark this moment (⌘B)"]?.hasPrefix("Marcar este momento") == true)
        XCTAssertTrue(en["Moments marked: %d"] != nil && pt["Moments marked: %d"]?.contains("marcados") == true)
        // Siri says what the button says.
        XCTAssertEqual(siriEN.keys.filter { $0.contains("moment") }, ["Mark this moment in ${applicationName}"])
        XCTAssertTrue(siriPT["Mark this moment in ${applicationName}"]?.hasPrefix("Marcar este momento") == true)
    }

    /// The display strings in code, not only the tables: an English literal
    /// with "Bookmark" in it would be shown as-is.
    func testNoScreenSaysBookmarkInCode() throws {
        let dirs = ["Sources/Ata", "Sources/AtaiOS", "Sources/AtaWatch", "Sources/AtaWidgets"]
        let shown = try NSRegularExpression(pattern: #"(L|Label|Text|Button|LocalizedStringResource|shortTitle:|phrases: \[|IntentDescription)\(?\s*"[^"]*[Bb]ookmark"#)
        var offenders: [String] = []
        for dir in dirs {
            let walker = FileManager.default.enumerator(at: Self.repo.appending(path: dir), includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                for line in source.split(separator: "\n") {
                    let s = String(line)
                    if shown.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                        offenders.append("\(url.lastPathComponent): \(s.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }
}

/// Shared-view type sizes on the iPhone.
final class ScaledTypeTests: XCTestCase {
    func testTheIPhoneNeverStartsBelowElevenPoints() {
        XCTAssertEqual(ScaledType.iOSBase(9), 11)
        XCTAssertEqual(ScaledType.iOSBase(10), 11)
        XCTAssertEqual(ScaledType.iOSBase(13), 13)
    }

    func testEachSizeGrowsLikeTheNearestTextStyle() {
        XCTAssertEqual(ScaledType.style(for: 9), .caption2)
        XCTAssertEqual(ScaledType.style(for: 11), .caption2)
        XCTAssertEqual(ScaledType.style(for: 12), .caption)
        XCTAssertEqual(ScaledType.style(for: 13), .footnote)
        XCTAssertEqual(ScaledType.style(for: 17), .body)
        XCTAssertEqual(ScaledType.style(for: 20), .title3)
    }
}
