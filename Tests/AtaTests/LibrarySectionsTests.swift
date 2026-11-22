@testable import Ata
import AppKit
import XCTest

/// Date sections in the library window, and the menu's "next meeting" line.
final class LibrarySectionsTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// 22 Nov 2026, 15:00 UTC. A Sunday.
    private var now: Date { date(2026, 11, 22, 15) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.minute = minute
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        return calendar.date(from: parts)!
    }

    private func meeting(_ id: String, _ at: Date) -> Meeting {
        Meeting(id: id, startedAt: at, endedAt: nil, duration: nil, app: id, status: .done, error: nil)
    }

    func testMeetingsGroupIntoTodayYesterdayAndMonth() {
        let meetings = [
            meeting("future", date(2026, 11, 25, 9)),
            meeting("today-late", date(2026, 11, 22, 16)),
            meeting("today-early", date(2026, 11, 22, 9)),
            meeting("yesterday", date(2026, 11, 21, 18)),
            meeting("earlier", date(2026, 11, 2, 9)),
            meeting("october", date(2026, 10, 30, 9)),
            meeting("last-year", date(2025, 11, 22, 9)),
        ]

        let groups = LibrarySections.group(meetings.shuffled(), now: now, calendar: calendar)

        XCTAssertEqual(groups.map(\.bucket), [
            .today, .yesterday, .earlierThisMonth, .month(year: 2026, month: 10), .month(year: 2025, month: 11),
        ])
        XCTAssertEqual(groups[0].meetings.map(\.id), ["today-late", "today-early"])
        XCTAssertEqual(groups[1].meetings.map(\.id), ["yesterday"])
        XCTAssertEqual(groups[2].meetings.map(\.id), ["future", "earlier"])
        XCTAssertEqual(groups[3].meetings.map(\.id), ["october"])
        XCTAssertEqual(groups[4].meetings.map(\.id), ["last-year"])
    }

    func testYesterdayOnTheFirstIsNotThisMonth() {
        let first = date(2026, 12, 1, 10)
        let groups = LibrarySections.group([
            meeting("today", date(2026, 12, 1, 8)),
            meeting("yesterday", date(2026, 11, 30, 22)),
            meeting("october", date(2026, 10, 3, 9)),
        ], now: first, calendar: calendar)

        XCTAssertEqual(groups.map(\.bucket), [
            .today, .yesterday, .month(year: 2026, month: 10),
        ])
    }

    func testAnEmptyLibraryHasNoSections() {
        XCTAssertEqual(LibrarySections.group([], now: now, calendar: calendar).count, 0)
    }

    func testSectionTitlesUseTheWordsAndTheMonthName() {
        XCTAssertEqual(LibrarySections.title(for: .today, now: now, calendar: calendar), L("Today"))
        XCTAssertEqual(LibrarySections.title(for: .yesterday, now: now, calendar: calendar), L("Yesterday"))
        XCTAssertEqual(LibrarySections.title(for: .earlierThisMonth, now: now, calendar: calendar), L("Earlier this month"))
        let october = LibrarySections.title(for: .month(year: 2026, month: 10), now: now, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        XCTAssertEqual(october, formatter.string(from: date(2026, 10, 1)))
        let lastNovember = LibrarySections.title(for: .month(year: 2025, month: 11), now: now, calendar: calendar)
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        XCTAssertEqual(lastNovember, formatter.string(from: date(2025, 11, 1)))
    }

    func testTheLibraryWindowOpensAtThePlanSize() {
        XCTAssertEqual(LibraryWindow.opening, NSSize(width: 900, height: 620))
        XCTAssertEqual(LibraryWindow.minSize, NSSize(width: 720, height: 480))
        XCTAssertEqual(LibraryWindow.contentMaxWidth, 720)
    }

    func testTheMenuShowsFiveRecentMeetings() {
        XCTAssertEqual(PopoverHome.recentLimit, 5)
        XCTAssertEqual(PopoverHome.width, 350)
    }
}

final class RecordCueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func upcoming(_ title: String, in seconds: TimeInterval) -> RecordCue.Upcoming {
        RecordCue.Upcoming(title: title, startsAt: now.addingTimeInterval(seconds))
    }

    func testADetectedCallWins() {
        let next = upcoming("Standup", in: 12 * 60)
        XCTAssertEqual(RecordCue.choose(detectedApp: "Zoom", upcoming: [next], now: now), .detected(app: "Zoom"))
        XCTAssertEqual(RecordCue.choose(detectedApp: "  Zoom  ", upcoming: [next], now: now), .detected(app: "Zoom"))
    }

    func testABlankDetectionFallsThrough() {
        let next = upcoming("Standup", in: 12 * 60)
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [next], now: now), .next(title: "Standup", minutes: 12))
        XCTAssertEqual(RecordCue.choose(detectedApp: "  ", upcoming: [next], now: now), .next(title: "Standup", minutes: 12))
    }

    func testTheSoonestMeetingInsideTheHorizon() {
        let later = upcoming("Planning", in: 3 * 3600)
        let sooner = upcoming("Standup", in: 12 * 60)
        let tomorrow = upcoming("Retro", in: 13 * 3600)
        XCTAssertEqual(
            RecordCue.choose(detectedApp: nil, upcoming: [later, tomorrow, sooner], now: now),
            .next(title: "Standup", minutes: 12))
    }

    func testMinutesRoundAndStayAtLeastOneUntilItStarts() {
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [upcoming("A", in: 90)], now: now),
                       .next(title: "A", minutes: 2))
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [upcoming("A", in: 30)], now: now),
                       .next(title: "A", minutes: 1))
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [upcoming("A", in: 12 * 3600)], now: now),
                       .next(title: "A", minutes: 12 * 60))
    }

    func testAMeetingUnderWayWithinGraceSaysNow() {
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [upcoming("A", in: -30)], now: now),
                       .next(title: "A", minutes: 0))
    }

    func testAMeetingOutsideGraceOrTheHorizonIsIdle() {
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [upcoming("A", in: -10 * 60)], now: now), .idle)
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [upcoming("A", in: 12 * 3600 + 60)], now: now), .idle)
        XCTAssertEqual(RecordCue.choose(detectedApp: nil, upcoming: [], now: now), .idle)
    }
}
