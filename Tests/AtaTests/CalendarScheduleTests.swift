@testable import Ata
import XCTest

/// Deciding which meetings to offer to record, with no calendar anywhere near it.
final class CalendarScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_440_800)
    private let lead: TimeInterval = 60

    private func candidacy(_ title: String, inMinutes: Double, people: Int = 1,
                           allDay: Bool = false, cancelled: Bool = false,
                           declined: Bool? = nil, free: Bool = false,
                           id: String? = nil) -> CalendarSchedule.Candidacy {
        let attendees = (0..<people).map { MeetingEvent.Attendee(name: "Person \($0)") }
            + [MeetingEvent.Attendee(name: "Me", isMe: true)]
        let event = MeetingEvent(title: title, startsAt: now.addingTimeInterval(inMinutes * 60),
                                 attendees: attendees, eventID: id)!
        return .init(event: event, isAllDay: allDay, isCancelled: cancelled,
                     iDeclined: declined, isFree: free)
    }

    private func offered(_ list: [CalendarSchedule.Candidacy]) -> [String] {
        CalendarSchedule.occurrences(in: list, now: now, lead: lead, peopleOnly: true).map(\.event.title)
    }

    func testAMeetingAboutToStartIsOffered() {
        XCTAssertEqual(offered([candidacy("Weekly sync", inMinutes: 1)]), ["Weekly sync"])
        XCTAssertEqual(offered([candidacy("Later", inMinutes: 180)]), ["Later"])
    }

    func testAnAllDayEventIsNeverOffered() {
        // Midnight, so a one-minute lead would ask at 23:59 the night before.
        XCTAssertEqual(offered([candidacy("Holiday", inMinutes: 600, allDay: true)]), [])
    }

    func testACancelledOrFreeEventIsNeverOffered() {
        XCTAssertEqual(offered([candidacy("Called off", inMinutes: 5, cancelled: true)]), [])
        XCTAssertEqual(offered([candidacy("Focus", inMinutes: 5, free: true)]), [])
    }

    func testAnEventYouDeclinedIsNotOffered() {
        XCTAssertEqual(offered([candidacy("Not going", inMinutes: 5, declined: true)]), [])
    }

    /// The pin for "could not tell is not a no": some accounts report no
    /// participants at all, and a missing prompt costs more than a stray one.
    func testAnEventTheCalendarWouldNotSayAboutIsStillOffered() {
        XCTAssertEqual(offered([candidacy("Unknown", inMinutes: 5, declined: nil)]), ["Unknown"])
    }

    func testABlockWithNobodyElseOnItIsNotAMeeting() {
        XCTAssertEqual(offered([candidacy("Write the thing", inMinutes: 5, people: 0)]), [])
        // …unless the user asked for those too.
        let alone = [candidacy("Write the thing", inMinutes: 5, people: 0)]
        XCTAssertEqual(CalendarSchedule.occurrences(in: alone, now: now, lead: lead, peopleOnly: false).count, 1)
    }

    func testAMeetingThatHasJustStartedIsStillOffered() {
        XCTAssertEqual(offered([candidacy("Started a minute ago", inMinutes: -1)]), ["Started a minute ago"])
    }

    /// A Mac that wakes at eleven must not offer to record the nine o'clock.
    func testAMeetingLongUnderWayIsNotOffered() {
        XCTAssertEqual(offered([candidacy("This morning", inMinutes: -120)]), [])
    }

    func testBeyondTheHorizonNothingIsScheduledYet() {
        XCTAssertEqual(offered([candidacy("Next week", inMinutes: 60 * 24 * 7)]), [])
    }

    func testOnlySoManyAreScheduledAtOnce() {
        let many = (1...50).map { candidacy("Meeting \($0)", inMinutes: Double($0)) }
        let out = CalendarSchedule.occurrences(in: many, now: now, lead: lead, peopleOnly: true)
        XCTAssertEqual(out.count, CalendarSchedule.maxScheduled)
        XCTAssertEqual(out.first?.event.title, "Meeting 1", "soonest first")
    }

    func testTheSoonestComeFirst() {
        XCTAssertEqual(offered([candidacy("Third", inMinutes: 30),
                                candidacy("First", inMinutes: 2),
                                candidacy("Second", inMinutes: 10)]),
                       ["First", "Second", "Third"])
    }

    // MARK: When to ask

    func testTheQuestionComesOneLeadBeforeItStarts() {
        let event = candidacy("Sync", inMinutes: 10).event
        XCTAssertEqual(CalendarSchedule.fireDate(for: event, lead: lead, now: now),
                       event.startsAt.addingTimeInterval(-lead))
    }

    /// A meeting starting in twenty seconds is still worth asking about, and
    /// the fire date has to be in the future for the system to deliver it.
    func testAMeetingStartingAnyMomentIsAskedAboutNow() {
        let event = candidacy("Sync", inMinutes: 0.33).event
        let fire = try! XCTUnwrap(CalendarSchedule.fireDate(for: event, lead: lead, now: now))
        XCTAssertGreaterThan(fire, now)
        XCTAssertLessThan(fire, now.addingTimeInterval(5))
    }

    func testOnceTheGraceHasPassedThereIsNothingToAsk() {
        let event = candidacy("Sync", inMinutes: -10).event
        XCTAssertNil(CalendarSchedule.fireDate(for: event, lead: lead, now: now))
    }

    // MARK: One meeting, one prompt

    func testEveryOccurrenceOfARecurringMeetingGetsItsOwnPrompt() {
        let monday = candidacy("Stand-up", inMinutes: 10, id: "recurring").event
        let tuesday = candidacy("Stand-up", inMinutes: 10 + 60 * 24, id: "recurring").event
        XCTAssertNotEqual(CalendarSchedule.key(for: monday), CalendarSchedule.key(for: tuesday),
                          "same event identifier, different meetings")
    }

    func testTwoDifferentMeetingsAtTheSameMomentDoNotCollide() {
        XCTAssertNotEqual(CalendarSchedule.key(for: candidacy("Sync", inMinutes: 10, id: "a").event),
                          CalendarSchedule.key(for: candidacy("Review", inMinutes: 10, id: "b").event))
    }

    func testAnEventWithNoIdentifierStillGetsAStableKey() {
        let a = candidacy("Weekly sync", inMinutes: 10).event
        let b = candidacy("Weekly  SYNC", inMinutes: 10).event
        XCTAssertEqual(CalendarSchedule.key(for: a), CalendarSchedule.key(for: b),
                       "the same meeting written two ways is one prompt")
    }

    /// Swift's `hashValue` is seeded per process: an identifier built from it
    /// would change at every launch and re-schedule every prompt. This pins the
    /// hash to a value a future refactor cannot quietly change.
    func testTheKeyIsTheSameInEveryProcess() {
        XCTAssertEqual(CalendarSchedule.stableHash("Weekly sync"), "1bohxtiod17cx")
        XCTAssertEqual(CalendarSchedule.stableHash(""), "33niihzj4ux45")
    }
}
