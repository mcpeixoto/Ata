@testable import Ata
import XCTest

/// Naming a meeting after a calendar event.
///
/// An app name came from the system and only ever needed a slash and a colon
/// taken out of it. An event's title is whatever the user typed into Calendar,
/// and it becomes a folder name — so it can hold a newline, a leading dot that
/// would hide the folder, or two hundred characters, which `createDirectory`
/// refuses outright. That refusal happens inside `startRecording`, where it
/// would mean no recording at all.
final class FolderLabelTests: XCTestCase {
    func testTheEventTitleNamesTheMeetingAndTheAppIsTheFallback() {
        let event = MeetingEvent(title: "Weekly sync", startsAt: Date())
        XCTAssertEqual(FolderNames.label(app: "Zoom", event: event), "Weekly sync")
        XCTAssertEqual(FolderNames.label(app: "Zoom", event: nil), "Zoom")
        XCTAssertNil(FolderNames.label(app: nil, event: nil))
    }

    func testAPathIsNeverBuiltOutOfATitle() {
        XCTAssertEqual(FolderNames.safe("1:1 with Rita"), "1-1 with Rita")
        XCTAssertEqual(FolderNames.safe("Design / review"), "Design - review")
        XCTAssertEqual(FolderNames.safe("Sync\nand plan"), "Sync and plan")
        XCTAssertEqual(FolderNames.safe("Sync\tand\u{0}plan"), "Sync and plan")
    }

    func testAHiddenOrEmptyFolderIsNeverMade() {
        XCTAssertNil(FolderNames.safe(".hidden".replacingOccurrences(of: "hidden", with: "")))
        XCTAssertNil(FolderNames.safe("."))
        XCTAssertNil(FolderNames.safe(".."))
        XCTAssertNil(FolderNames.safe("   "))
        XCTAssertNil(FolderNames.safe(nil))
        XCTAssertEqual(FolderNames.safe(".hidden"), "hidden", "a leading dot would hide the folder")
    }

    func testEmojiSurviveBecauseTheTitleIsTheirs() {
        XCTAssertEqual(FolderNames.safe("🚀 Launch"), "🚀 Launch")
    }

    /// The cap is in bytes, but cutting must land on whole characters: half an
    /// emoji is not a file name, it is invalid UTF-8.
    func testALongTitleIsCutToWholeCharacters() {
        let long = String(repeating: "🚀", count: 200)
        let safe = try! XCTUnwrap(FolderNames.safe(long))
        XCTAssertLessThanOrEqual(safe.utf8.count, 180)
        XCTAssertFalse(safe.isEmpty)
        XCTAssertTrue(safe.allSatisfy { $0 == "🚀" }, "cut between characters, never inside one")
        XCTAssertEqual(String(decoding: Array(safe.utf8), as: UTF8.self), safe, "still valid UTF-8")
    }

    func testTheFolderNameIsTheDateAndTheTitle() {
        let at = Date(timeIntervalSince1970: 1_793_440_925)
        let event = MeetingEvent(title: "Weekly sync", startsAt: at)
        let name = FolderNames.name(startedAt: at, app: "Zoom", event: event)
        XCTAssertTrue(name.hasSuffix(" Weekly sync"), name)
        XCTAssertEqual(FolderNames.name(startedAt: at, app: nil, event: nil).count, 19, "just the timestamp")
    }
}

/// What a meeting keeps of the event it was recorded for.
final class MeetingEventTests: XCTestCase {
    private func attendee(_ name: String, _ email: String? = nil, me: Bool = false) -> MeetingEvent.Attendee {
        MeetingEvent.Attendee(name: name, email: email, isMe: me)
    }

    func testAnEventWithNoTitleIsNotAnEvent() {
        XCTAssertNil(MeetingEvent(title: "   \n ", startsAt: Date()))
        XCTAssertNil(MeetingEvent(title: "", startsAt: Date()))
        XCTAssertEqual(MeetingEvent(title: "  Weekly sync  ", startsAt: Date())?.title, "Weekly sync")
    }

    /// A two-hundred-person all-hands must not put two hundred names into a
    /// meeting.json that syncs to every device the user owns.
    func testAHugeInvitationIsCappedAndCounted() {
        let many = (1...200).map { attendee("Person \($0)") }
        let event = MeetingEvent(title: "All hands", startsAt: Date(), attendees: many)
        XCTAssertEqual(event?.attendees.count, MeetingEvent.attendeeLimit)
        XCTAssertEqual(event?.attendeeTotal, 200)
    }

    func testASmallInvitationCountsNothingExtra() {
        let event = MeetingEvent(title: "1:1", startsAt: Date(), attendees: [attendee("Rita")])
        XCTAssertNil(event?.attendeeTotal, "nothing was left out, so there is nothing to say")
    }

    func testYouAreNeverOneOfTheOthers() {
        let event = MeetingEvent(title: "Sync", startsAt: Date(),
                                 attendees: [attendee("Me", me: true), attendee("Rita")])
        XCTAssertEqual(event?.others.map(\.name), ["Rita"])
    }

    /// The same strategy `Library` saves meetings with (`Meeting.swift`).
    private func coders() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }

    func testTheEventSurvivesBeingSavedAndReadBack() throws {
        let event = try XCTUnwrap(MeetingEvent(title: "Weekly sync", startsAt: Date(timeIntervalSince1970: 1_793_440_925),
                                               attendees: [attendee("Rita Alves", "rita@acme.com")],
                                               calendarName: "Work", eventID: "abc"))
        var m = Meeting(id: "x", startedAt: Date(), endedAt: nil, duration: nil,
                        app: "Zoom", status: .done, error: nil)
        m.event = event
        let (encoder, decoder) = coders()
        let data = try encoder.encode(m)
        let read = try decoder.decode(Meeting.self, from: data)
        XCTAssertEqual(read.event, event)
    }

    /// The backwards-compatibility pin: every meeting recorded before 2.11.
    func testAMeetingFromBeforeCalendarsStillReads() throws {
        let json = """
        {"id":"2026-10-23 14.02.05 Zoom","startedAt":"2026-10-23T14:02:05Z","app":"Zoom","status":"done"}
        """
        let m = try coders().1.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertNil(m.event)
        XCTAssertEqual(m.title, "Zoom")
    }

    func testWhatAMeetingIsCalled() {
        var m = Meeting(id: "x", startedAt: Date(), endedAt: nil, duration: nil,
                        app: "Zoom", status: .done, error: nil)
        XCTAssertEqual(m.title, "Zoom")
        m.event = MeetingEvent(title: "Weekly sync", startsAt: Date())
        XCTAssertEqual(m.title, "Weekly sync", "the event wins")
        m.event = nil
        m.app = nil
        XCTAssertEqual(m.title, "Meeting")
    }
}

/// Insights counts time per app, not per meeting.
///
/// `Meeting.title` used to be the app, so grouping by it was the same thing.
/// Now that a title can be a calendar event's, grouping by title would give one
/// bar per meeting — "Weekly sync", "1:1 with Rita", "Design review" — and the
/// "Where" chart would still render, just wrong. That is the kind of regression
/// that ships silently, so it gets a test of its own.
final class InsightsCalendarTests: XCTestCase {
    func testTwoCalendarMeetingsInOneAppAreOneBar() {
        let now = Date(timeIntervalSince1970: 1_792_584_000)
        func meeting(_ id: String, _ title: String, minutes: Double) -> Meeting {
            var m = Meeting(id: id, startedAt: now.addingTimeInterval(-3_600), endedAt: nil,
                            duration: minutes * 60, app: "Zoom", status: .done, error: nil)
            m.event = MeetingEvent(title: title, startsAt: now)
            // The timeline is built from transcription records, so the fixture
            // needs one for each meeting to appear in it at all.
            m.transcriptions = [TranscriptionRecord(engine: "local", model: "large-v3", finishedAt: now,
                                                    audioSeconds: minutes * 60, processingSeconds: 1,
                                                    costUSD: 0, words: 100, mySpeechSeconds: 10,
                                                    othersSpeechSeconds: 10, archivedAs: nil)]
            return m
        }
        let i = Insights.compute([meeting("a", "Weekly sync", minutes: 30),
                                  meeting("b", "Design review", minutes: 20)],
                                 myName: "Alex", now: now)

        XCTAssertEqual(i.apps.map(\.name), ["Zoom"], "one bar for the app, not one per meeting")
        XCTAssertEqual(i.apps.first?.minutes, 50)
        // The timeline is a list of meetings, so there the title is exactly right.
        XCTAssertEqual(Set(i.timeline.map(\.meetingTitle)), ["Weekly sync", "Design review"])
    }

    /// A meeting with no app at all keeps the bucket it had before this change.
    func testAMeetingWithNoAppIsStillCountedSomewhere() {
        let now = Date(timeIntervalSince1970: 1_792_584_000)
        var m = Meeting(id: "a", startedAt: now, endedAt: nil, duration: 600,
                        app: nil, status: .done, error: nil)
        m.event = MeetingEvent(title: "Weekly sync", startsAt: now)
        let i = Insights.compute([m], myName: "Alex", now: now)
        XCTAssertEqual(i.apps.map(\.name), ["Meeting"])
    }
}
