@testable import Ata
import XCTest

/// Work or personal: how a meeting gets its category, and that it survives
/// meeting.json being read and written by older code and older copies.
final class MeetingCategoryTests: XCTestCase {
    /// The one temporary meetings folder the test run has: the location is
    /// read once per process, so every disk test shares `FilesTests`'.
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // MARK: Decoding

    func testAMeetingFromBeforeCategoriesHasNone() throws {
        let json = """
        {"id": "old", "startedAt": "2026-01-02T10:00:00Z", "app": "Zoom", "status": "done"}
        """
        let m = try Self.decoder.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertNil(m.category)
        XCTAssertNil(m.categoryValue)
    }

    func testACategoryFromALaterAtaStillReads() throws {
        let json = """
        {"id": "new", "startedAt": "2026-01-02T10:00:00Z", "status": "done",
         "category": {"value": "family", "manual": true, "at": "2026-01-03T10:00:00Z"}}
        """
        let m = try Self.decoder.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertEqual(m.category?.value, "family", "kept as it was, so writing it back loses nothing")
        XCTAssertNil(m.categoryValue, "but this Ata doesn't know it, so it files it nowhere")

        let again = try Self.decoder.decode(Meeting.self, from: Self.encoder.encode(m))
        XCTAssertEqual(again.category?.value, "family")
    }

    func testAKnownCategoryRoundTrips() throws {
        var m = Meeting(id: "x", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil,
                        duration: nil, app: nil, status: .done, error: nil)
        m.category = CategoryTag(value: "personal", manual: true, at: Date(timeIntervalSince1970: 1_800_000_100))
        let again = try Self.decoder.decode(Meeting.self, from: Self.encoder.encode(m))
        XCTAssertEqual(again.categoryValue, .personal)
        XCTAssertEqual(again.category, m.category)
    }

    // MARK: Guessing

    func testTheCalendarWinsOverTheApp() {
        let map = ["cal-home": "personal", "cal-work": "work"]
        XCTAssertEqual(MeetingCategory.guess(app: "Zoom", calendarID: "cal-home", calendarName: nil,
                                             calendarMap: map, default: nil), .personal)
        XCTAssertEqual(MeetingCategory.guess(app: "FaceTime", calendarID: "cal-work", calendarName: nil,
                                             calendarMap: map, default: .personal), .work)
    }

    func testAnOldEventWithoutAnIdentifierMatchesByCalendarName() {
        XCTAssertEqual(MeetingCategory.guess(app: nil, calendarID: nil, calendarName: "Family",
                                             calendarMap: ["Family": "personal"], default: .work), .personal)
    }

    func testAnUnmappedCalendarFallsThroughToTheApp() {
        XCTAssertEqual(MeetingCategory.guess(app: "Teams", calendarID: "other", calendarName: "Other",
                                             calendarMap: ["cal-home": "personal"], default: .personal), .work)
    }

    func testTheAppDecidesWhenThereIsNoCalendar() {
        for app in ["Zoom", "Teams", "Microsoft Teams", "Slack", "Webex", "Around", "Tuple", "Google Meet"] {
            XCTAssertEqual(MeetingCategory.guess(app: app, calendarID: nil, calendarName: nil,
                                                 calendarMap: [:], default: .personal), .work, app)
        }
        for app in ["FaceTime", "WhatsApp", "Discord", "Skype", "Messenger"] {
            XCTAssertEqual(MeetingCategory.guess(app: app, calendarID: nil, calendarName: nil,
                                                 calendarMap: [:], default: .work), .personal, app)
        }
    }

    func testABrowserOrAnUnknownAppSaysNothingAndTheDefaultApplies() {
        for app in ["Chrome", "Safari", "Arc", "iPhone", nil] as [String?] {
            XCTAssertNil(MeetingCategory.guess(app: app, calendarID: nil, calendarName: nil,
                                               calendarMap: [:], default: nil), app ?? "nil")
            XCTAssertEqual(MeetingCategory.guess(app: app, calendarID: nil, calendarName: nil,
                                                 calendarMap: [:], default: .work), .work, app ?? "nil")
        }
    }

    func testAMappingToAnUnknownValueIsIgnored() {
        XCTAssertEqual(MeetingCategory.guess(app: "Zoom", calendarID: "c", calendarName: nil,
                                             calendarMap: ["c": "family"], default: nil), .work)
    }

    func testTheFilter() {
        var m = Meeting(id: "f", startedAt: Date(), endedAt: nil, duration: nil, app: nil, status: .done, error: nil)
        XCTAssertTrue(MeetingCategory.matches(m, filter: ""))
        XCTAssertFalse(MeetingCategory.matches(m, filter: "work"))
        m.category = CategoryTag(value: "work", manual: false, at: Date())
        XCTAssertTrue(MeetingCategory.matches(m, filter: "work"))
        XCTAssertFalse(MeetingCategory.matches(m, filter: "personal"))
        m.category = .cleared()
        XCTAssertFalse(MeetingCategory.matches(m, filter: "work"))
        XCTAssertTrue(MeetingCategory.matches(m, filter: ""))
    }

    // MARK: Saving

    /// A recording that stops, or a transcript that finishes, saves the copy of
    /// the meeting it has held since it started. The user may have picked a
    /// category in between; that pick must survive.
    func testSavingAStaleCopyKeepsTheNewerCategoryOnDisk() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = try Meeting.new(app: "Zoom", at: start)
        stale.category = CategoryTag(value: "work", manual: false, at: start)
        Library.save(stale)

        // The user files it as personal, from the meeting window.
        var picked = try XCTUnwrap(Library.load(stale.id))
        picked.category = CategoryTag(value: "personal", manual: true, at: start.addingTimeInterval(60))
        Library.save(picked)

        // The recorder finishes with the copy it had.
        stale.status = .pending
        stale.duration = 120
        Library.save(stale)

        let now = try XCTUnwrap(Library.load(stale.id))
        XCTAssertEqual(now.categoryValue, .personal, "the user's newer choice")
        XCTAssertEqual(now.category?.manual, true)
        XCTAssertEqual(now.status, .pending, "and everything else from the copy being saved")
        XCTAssertEqual(now.duration, 120)
    }

    func testANewerCategoryInMemoryReplacesTheOneOnDisk() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var m = try Meeting.new(app: "Chrome", at: start)
        m.category = CategoryTag(value: "work", manual: false, at: start)
        Library.save(m)
        m.category = CategoryTag(value: "personal", manual: true, at: start.addingTimeInterval(5))
        Library.save(m)
        XCTAssertEqual(Library.load(m.id)?.categoryValue, .personal)
    }

    func testTakingTheCategoryAwayStaysTakenAway() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var stale = try Meeting.new(app: "Slack", at: start)
        stale.category = CategoryTag(value: "work", manual: false, at: start)
        Library.save(stale)

        var cleared = stale
        cleared.category = .cleared(at: start.addingTimeInterval(30))
        Library.save(cleared)

        Library.save(stale)
        let now = try XCTUnwrap(Library.load(stale.id))
        XCTAssertNil(now.categoryValue, "an older copy does not bring Work back")
        XCTAssertEqual(now.category?.value, "")
    }

    func testANewMeetingFromAWorkAppStartsAsWork() throws {
        let m = try Meeting.new(app: "Zoom")
        XCTAssertEqual(m.categoryValue, .work)
        XCTAssertEqual(m.category?.manual, false)
    }

    // MARK: Calendar

    func testTheEventKeepsItsCalendarIdentifier() throws {
        let event = try XCTUnwrap(MeetingEvent(title: "Stand-up", startsAt: Date(timeIntervalSince1970: 1_800_000_000),
                                               calendarName: "Work", eventID: "e1", calendarID: "cal-1"))
        let json = try XCTUnwrap(MeetingEventCoding.json(event))
        XCTAssertEqual(MeetingEventCoding.event(json)?.calendarID, "cal-1")
        XCTAssertEqual(MeetingEventCoding.event(json), event)
    }

    func testAnEventSavedBeforeCalendarIdentifiersStillReads() throws {
        let json = """
        {"title": "Stand-up", "startsAt": "2026-01-02T10:00:00Z", "attendees": [], "calendarName": "Work"}
        """
        let event = try XCTUnwrap(MeetingEventCoding.event(json))
        XCTAssertNil(event.calendarID)
        XCTAssertEqual(event.calendarName, "Work")
    }
}
