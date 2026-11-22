@testable import Ata
import XCTest

/// Search over a meeting's title, subtitle, category and transcript. The text
/// is passed in: reading the transcript file is the caller's job, as on the
/// iPhone, so this stays pure and never touches the meetings folder.
final class MeetingSearchTests: XCTestCase {
    private func meeting(app: String? = "Zoom", title: String? = nil, duration: Double? = 42 * 60,
                         category: String? = nil, at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Meeting {
        var m = Meeting(id: "m", startedAt: date, endedAt: nil, duration: duration, app: app,
                        status: .done, error: nil)
        if let title {
            m.event = MeetingEvent(title: title, startsAt: date)
        }
        if let category {
            m.category = CategoryTag(value: category, manual: true, at: date)
        }
        return m
    }

    func testAnEmptyQueryMatchesEverything() {
        let m = meeting()
        XCTAssertTrue(m.matches(""))
        XCTAssertTrue(m.matches("   "))
        XCTAssertTrue(m.matches("\n\t"))
    }

    func testTheTitleMatchesIgnoringCase() {
        let m = meeting(app: "Zoom")
        XCTAssertTrue(m.matches("zoom"))
        XCTAssertTrue(m.matches("ZOOM"))
        XCTAssertFalse(m.matches("slack"))
    }

    func testAnEventTitleIsTheTitle() {
        let m = meeting(app: "Zoom", title: "Client standup")
        XCTAssertTrue(m.matches("client"))
        XCTAssertFalse(m.matches("zoom"), "the calendar title replaces the app name, as the row does")
    }

    func testTheSubtitleIsSearched() {
        let m = meeting(duration: 42 * 60)
        let minutes = m.subtitle.components(separatedBy: " · ").last ?? ""
        XCTAssertFalse(minutes.isEmpty)
        XCTAssertTrue(m.matches(minutes))
        XCTAssertTrue(m.matches(m.subtitle))
    }

    func testTheTranscriptIsSearchedIgnoringCase() {
        let m = meeting(app: "Slack")
        XCTAssertTrue(m.matches("friday", transcript: "Friday it is. Rita sends the copy."))
        XCTAssertFalse(m.matches("friday"))
        XCTAssertFalse(m.matches("pricing", transcript: "Friday it is."))
    }

    func testTheCategoryNameIsSearched() {
        let m = meeting(app: "FaceTime", category: "personal")
        let name = m.categoryValue?.name ?? ""
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(m.matches(name))
        XCTAssertTrue(m.matches(name.uppercased()))
        let other = MeetingCategory.work.name
        XCTAssertNotEqual(name.lowercased(), other.lowercased())
        XCTAssertFalse(m.matches(other))
    }
}
