import Foundation

/// What the Record tab shows, decided without SwiftUI so ios/Tests can check it.
/// Foundation only: the test bundle compiles this file on its own.
enum RecordHomeModel {
    // MARK: Layout

    enum Layout: Equatable { case idle, recording }

    /// Stopping keeps the recording layout, so the timer stays up while the
    /// file is saved instead of jumping back to the idle screen and then
    /// sprouting a transcribing card. Starting stays idle until audio flows.
    static func layout(isRecording: Bool, isStopping: Bool) -> Layout {
        isRecording || isStopping ? .recording : .idle
    }

    /// The line under the button.
    enum ButtonCaption: Equatable { case tapToRecord, starting, saving, none }

    static func caption(isStarting: Bool, isStopping: Bool, isRecording: Bool) -> ButtonCaption {
        if isStarting { return .starting }
        if isStopping { return .saving }
        return isRecording ? .none : .tapToRecord
    }

    /// "Saved. Transcribing now." after a stop that ended back at idle without an error.
    static func showsSavedToast(wasStopping: Bool, isIdle: Bool, failed: Bool) -> Bool {
        wasStopping && isIdle && !failed
    }

    // MARK: Greeting

    enum Greeting: Equatable { case morning, afternoon, evening }

    /// Morning from 5:00, afternoon from 12:00, evening from 18:00 until 4:59.
    static func greeting(hour: Int) -> Greeting {
        switch hour {
        case 5..<12: return .morning
        case 12..<18: return .afternoon
        default: return .evening
        }
    }

    /// The name to greet, or nil. The stored name falls back to "Me" until one
    /// is typed, and "Good morning, Me" is not a greeting.
    static func greetingName(stored: String?, placeholder: String) -> String? {
        let name = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, name != placeholder else { return nil }
        return name
    }

    // MARK: This week

    struct Week: Equatable {
        var meetings: Int
        var minutes: Double
    }

    /// Meetings that started in the calendar week `now` is in. The same week
    /// `Insights.compute` buckets by, counted here from start and length alone:
    /// `compute` also reads every transcript for talk time, which this line
    /// does not need on each redraw of the home.
    static func week(_ meetings: [(start: Date, seconds: Double)], now: Date,
                     calendar: Calendar = .current) -> Week {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return Week(meetings: 0, minutes: 0)
        }
        var out = Week(meetings: 0, minutes: 0)
        for m in meetings where interval.contains(m.start) {
            out.meetings += 1
            out.minutes += max(m.seconds, 0) / 60
        }
        return out
    }

    /// The summary line, or nil for "Ready when you are": an empty library,
    /// or a week with nothing in it yet.
    static func summary(libraryIsEmpty: Bool, week: Week) -> Week? {
        guard !libraryIsEmpty, week.meetings > 0 else { return nil }
        return week
    }

    // MARK: Cards

    /// Recent meetings shown under the button.
    static let recentCount = 3

    struct Cards: Equatable {
        var quotaBanner = false
        var transcribing = false
        var recents = false
        var firstRun = false
        var quotaMeter = false
        var tip: Tip?
    }

    static func cards(libraryIsEmpty: Bool, transcribing: Bool, isPro: Bool,
                      usedMinutes: Int, limitMinutes: Int, bannerDismissedThisMonth: Bool,
                      tip: Tip?) -> Cards {
        Cards(quotaBanner: showsQuotaBanner(usedMinutes: usedMinutes, limitMinutes: limitMinutes,
                                            isPro: isPro, dismissedThisMonth: bannerDismissedThisMonth),
              transcribing: transcribing,
              recents: !libraryIsEmpty,
              firstRun: libraryIsEmpty,
              quotaMeter: !isPro,
              tip: tip)
    }

    /// "N free minutes left" once 80 % of the month is used: the same point
    /// where `QuotaMeter` turns to the warning colour. Pro never sees it, and
    /// a dismissal holds until the next month.
    /// Track 3's `ProPrompt` will own this rule (the eighty-percent trigger);
    /// when it lands, this should ask it instead of deciding here.
    static func showsQuotaBanner(usedMinutes: Int, limitMinutes: Int, isPro: Bool,
                                 dismissedThisMonth: Bool) -> Bool {
        guard !isPro, !dismissedThisMonth, limitMinutes > 0, usedMinutes > 0 else { return false }
        return usedMinutes * 5 >= limitMinutes * 4
    }

    /// "2026-11": the month a banner dismissal belongs to.
    static func month(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    static func dismissedThisMonth(stored: String, now: Date, calendar: Calendar = .current) -> Bool {
        !stored.isEmpty && stored == month(now, calendar: calendar)
    }

    // MARK: Tips

    /// Ways to start recording without opening Ata. One a day; a dismissed tip
    /// leaves the rotation for good.
    enum Tip: String, CaseIterable {
        case lockScreen, actionButton, siri, widget
    }

    static func tip(day: Int, dismissed: Set<Tip>) -> Tip? {
        let left = Tip.allCases.filter { !dismissed.contains($0) }
        guard !left.isEmpty else { return nil }
        let i = ((day % left.count) + left.count) % left.count
        return left[i]
    }

    /// Whole days since 1 January 2001 in `calendar`, so the tip turns over at
    /// local midnight.
    static func dayIndex(_ date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// Dismissed tips as stored in UserDefaults: raw values, comma-separated.
    static func decodeTips(_ stored: String) -> Set<Tip> {
        Set(stored.split(separator: ",").compactMap { Tip(rawValue: String($0)) })
    }

    static func encodeTips(_ tips: Set<Tip>) -> String {
        Tip.allCases.filter(tips.contains).map(\.rawValue).joined(separator: ",")
    }

    /// UserDefaults keys. Kept with the model rather than in `Pref`: only this tab reads them.
    static let bannerDismissedMonthKey = "recordHomeBannerDismissedMonth"
    static let dismissedTipsKey = "recordHomeDismissedTips"
}
