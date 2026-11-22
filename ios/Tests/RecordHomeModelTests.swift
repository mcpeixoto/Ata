import XCTest

// RecordHomeModel.swift is compiled into this bundle, so the Record tab's
// decisions are tested without launching Ata.
final class RecordHomeModelTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        c.firstWeekday = 2
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testGreetingBoundariesAreFiveTwelveAndEighteen() {
        XCTAssertEqual(RecordHomeModel.greeting(hour: 4), .evening)
        XCTAssertEqual(RecordHomeModel.greeting(hour: 5), .morning)
        XCTAssertEqual(RecordHomeModel.greeting(hour: 11), .morning)
        XCTAssertEqual(RecordHomeModel.greeting(hour: 12), .afternoon)
        XCTAssertEqual(RecordHomeModel.greeting(hour: 17), .afternoon)
        XCTAssertEqual(RecordHomeModel.greeting(hour: 18), .evening)
        XCTAssertEqual(RecordHomeModel.greeting(hour: 23), .evening)
        XCTAssertEqual(RecordHomeModel.greeting(hour: 0), .evening)
    }

    func testGreetingSkipsTheMePlaceholderAndBlankNames() {
        XCTAssertNil(RecordHomeModel.greetingName(stored: nil, placeholder: "Me"))
        XCTAssertNil(RecordHomeModel.greetingName(stored: "  ", placeholder: "Me"))
        XCTAssertNil(RecordHomeModel.greetingName(stored: "Me", placeholder: "Me"))
        XCTAssertEqual(RecordHomeModel.greetingName(stored: " Miguel ", placeholder: "Me"), "Miguel")
    }

    func testWeekCountsOnlyThisWeeksMeetings() {
        let now = date(2026, 11, 19) // Thursday; the week starts Monday the 16th
        let week = RecordHomeModel.week([
            (date(2026, 11, 16, 9), 600),
            (date(2026, 11, 18), 1800),
            (date(2026, 11, 15, 23), 3600), // Sunday, last week
            (date(2026, 11, 24), 60),        // next week
        ], now: now, calendar: calendar)
        XCTAssertEqual(week, RecordHomeModel.Week(meetings: 2, minutes: 40))
    }

    func testEmptyLibraryIsReadyWhenYouAreAndShowsTheFirstRunCard() {
        let week = RecordHomeModel.week([], now: date(2026, 11, 19), calendar: calendar)
        XCTAssertNil(RecordHomeModel.summary(libraryIsEmpty: true, week: week))
        XCTAssertNil(RecordHomeModel.summary(libraryIsEmpty: false, week: week))
        XCTAssertEqual(RecordHomeModel.summary(libraryIsEmpty: false, week: .init(meetings: 1, minutes: 5)),
                       .init(meetings: 1, minutes: 5))

        let cards = RecordHomeModel.cards(libraryIsEmpty: true, transcribing: false, isPro: false,
                                          usedMinutes: 0, limitMinutes: 300,
                                          bannerDismissedThisMonth: false, tip: nil)
        XCTAssertTrue(cards.firstRun)
        XCTAssertFalse(cards.recents)
        XCTAssertFalse(cards.quotaBanner)
        XCTAssertTrue(cards.quotaMeter)
    }

    func testProHidesTheMeterAndTheBanner() {
        let cards = RecordHomeModel.cards(libraryIsEmpty: false, transcribing: true, isPro: true,
                                          usedMinutes: 299, limitMinutes: 300,
                                          bannerDismissedThisMonth: false, tip: .siri)
        XCTAssertFalse(cards.quotaMeter)
        XCTAssertFalse(cards.quotaBanner)
        XCTAssertTrue(cards.recents)
        XCTAssertTrue(cards.transcribing)
        XCTAssertEqual(cards.tip, .siri)
    }

    func testBannerFromEightyPercentUntilDismissedThisMonth() {
        XCTAssertFalse(RecordHomeModel.showsQuotaBanner(usedMinutes: 239, limitMinutes: 300, isPro: false, dismissedThisMonth: false))
        XCTAssertTrue(RecordHomeModel.showsQuotaBanner(usedMinutes: 240, limitMinutes: 300, isPro: false, dismissedThisMonth: false))
        XCTAssertTrue(RecordHomeModel.showsQuotaBanner(usedMinutes: 300, limitMinutes: 300, isPro: false, dismissedThisMonth: false))
        XCTAssertFalse(RecordHomeModel.showsQuotaBanner(usedMinutes: 240, limitMinutes: 300, isPro: true, dismissedThisMonth: false))
        XCTAssertFalse(RecordHomeModel.showsQuotaBanner(usedMinutes: 240, limitMinutes: 300, isPro: false, dismissedThisMonth: true))
        XCTAssertFalse(RecordHomeModel.showsQuotaBanner(usedMinutes: 0, limitMinutes: 0, isPro: false, dismissedThisMonth: false))
    }

    func testBannerDismissalEndsWithTheMonth() {
        let november = date(2026, 11, 30, 22)
        let stored = RecordHomeModel.month(november, calendar: calendar)
        XCTAssertEqual(stored, "2026-11")
        XCTAssertTrue(RecordHomeModel.dismissedThisMonth(stored: stored, now: november, calendar: calendar))
        XCTAssertFalse(RecordHomeModel.dismissedThisMonth(stored: stored, now: date(2026, 12, 1, 8), calendar: calendar))
        XCTAssertFalse(RecordHomeModel.dismissedThisMonth(stored: "", now: november, calendar: calendar))
    }

    func testTipRotatesByDayAndSkipsDismissedOnes() {
        let all = RecordHomeModel.Tip.allCases
        for day in 0..<8 {
            XCTAssertEqual(RecordHomeModel.tip(day: day, dismissed: []), all[day % all.count])
        }
        XCTAssertNotNil(RecordHomeModel.tip(day: -3, dismissed: []))
        let dismissed: Set<RecordHomeModel.Tip> = [.lockScreen, .siri]
        for day in 0..<6 {
            let tip = RecordHomeModel.tip(day: day, dismissed: dismissed)
            XCTAssertNotNil(tip)
            XCTAssertFalse(dismissed.contains(tip!))
        }
        XCTAssertNil(RecordHomeModel.tip(day: 4, dismissed: Set(all)))
    }

    func testDayIndexTurnsOverAtLocalMidnight() {
        let late = RecordHomeModel.dayIndex(date(2026, 11, 19, 23), calendar: calendar)
        let early = RecordHomeModel.dayIndex(date(2026, 11, 19, 0), calendar: calendar)
        let next = RecordHomeModel.dayIndex(date(2026, 11, 20, 0), calendar: calendar)
        XCTAssertEqual(late, early)
        XCTAssertEqual(next, late + 1)
    }

    func testDismissedTipsRoundTripThroughDefaults() {
        let tips: Set<RecordHomeModel.Tip> = [.widget, .actionButton]
        XCTAssertEqual(RecordHomeModel.decodeTips(RecordHomeModel.encodeTips(tips)), tips)
        XCTAssertEqual(RecordHomeModel.decodeTips("siri,bogus,"), [.siri])
        XCTAssertEqual(RecordHomeModel.decodeTips(""), [])
    }

    func testStoppingKeepsTheRecordingLayoutAndSaysSaving() {
        XCTAssertEqual(RecordHomeModel.layout(isRecording: false, isStopping: false), .idle)
        XCTAssertEqual(RecordHomeModel.layout(isRecording: true, isStopping: false), .recording)
        XCTAssertEqual(RecordHomeModel.layout(isRecording: false, isStopping: true), .recording)

        XCTAssertEqual(RecordHomeModel.caption(isStarting: false, isStopping: false, isRecording: false), .tapToRecord)
        XCTAssertEqual(RecordHomeModel.caption(isStarting: true, isStopping: false, isRecording: false), .starting)
        XCTAssertEqual(RecordHomeModel.caption(isStarting: false, isStopping: true, isRecording: false), .saving)
        XCTAssertEqual(RecordHomeModel.caption(isStarting: false, isStopping: false, isRecording: true), .none)
    }

    func testSavedToastOnlyAfterAStopThatSucceeded() {
        XCTAssertTrue(RecordHomeModel.showsSavedToast(wasStopping: true, isIdle: true, failed: false))
        XCTAssertFalse(RecordHomeModel.showsSavedToast(wasStopping: true, isIdle: true, failed: true))
        XCTAssertFalse(RecordHomeModel.showsSavedToast(wasStopping: false, isIdle: true, failed: false))
        XCTAssertFalse(RecordHomeModel.showsSavedToast(wasStopping: true, isIdle: false, failed: false))
    }
}
