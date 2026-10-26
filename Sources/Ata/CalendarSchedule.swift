import Foundation

/// Which meetings on the calendar are worth offering to record, and when to ask.
///
/// Pure, and deliberately knows nothing about EventKit: everything here can be
/// tested on a machine with an empty calendar, which is every machine CI runs on.
enum CalendarSchedule {
    /// What deciding needs to know about an event beyond `MeetingEvent` —
    /// things that matter for whether to offer it, and not afterwards.
    struct Candidacy: Equatable {
        var event: MeetingEvent
        var isAllDay: Bool = false
        var isCancelled: Bool = false
        /// You said no. **Nil when the calendar did not say.**
        ///
        /// `EKParticipant.isCurrentUser` is not reliable across account types —
        /// some CalDAV and Google calendars report no participants at all. So a
        /// definite no is dropped and a "could not tell" is kept: a prompt the
        /// user dismisses costs a tap, a missing prompt costs the recording.
        var iDeclined: Bool? = nil
        /// Marked "free" rather than "busy": usually a hold, not a meeting.
        var isFree: Bool = false
    }

    /// At most this many prompts are scheduled at once. The system caps an app's
    /// pending notification requests (documented at 64); this leaves room for
    /// Ata's own — a recording banner, a finished transcript, an update.
    static let maxScheduled = 32

    /// How long after an event has started it is still worth offering. Without
    /// it, a Mac that wakes at eleven would offer to record the nine o'clock
    /// stand-up; with it, a meeting you joined two minutes late still prompts.
    static let grace: TimeInterval = 120

    /// How far ahead to schedule. A day plus slack, so a Mac asleep over a long
    /// weekend still has Monday morning's prompts waiting when it opens.
    static let horizon: TimeInterval = 36 * 3600

    /// The meetings to have a prompt scheduled for, soonest first.
    static func occurrences(in events: [Candidacy], now: Date, lead: TimeInterval,
                            peopleOnly: Bool, max limit: Int = maxScheduled) -> [Candidacy] {
        events
            .filter { isWorthOffering($0, now: now, lead: lead, peopleOnly: peopleOnly) }
            .sorted { $0.event.startsAt < $1.event.startsAt }
            .prefix(limit)
            .map { $0 }
    }

    static func isWorthOffering(_ c: Candidacy, now: Date, lead: TimeInterval, peopleOnly: Bool) -> Bool {
        // An all-day event has no start instant worth prompting for: EventKit
        // puts it at midnight, so a one-minute lead would ask at 23:59 the night
        // before. Holidays, birthdays and out-of-office are all all-day.
        guard !c.isAllDay, !c.isCancelled, !c.isFree else { return false }
        guard c.iDeclined != true else { return false }
        // A block on your own calendar with nobody else on it is not a meeting.
        // This one filter removes focus time, reminders, holidays and birthdays
        // without asking the user to curate a list of calendars.
        if peopleOnly, c.event.others.isEmpty { return false }
        guard let fire = fireDate(for: c.event, lead: lead, now: now) else { return false }
        return fire <= now.addingTimeInterval(horizon)
    }

    /// When to ask about this meeting, or nil when the moment has passed.
    ///
    /// Normally `lead` before it starts. A meeting already under way, but by
    /// less than `grace`, is asked about now — the user opened the lid late and
    /// the meeting is still worth recording.
    static func fireDate(for event: MeetingEvent, lead: TimeInterval, now: Date) -> Date? {
        let wanted = event.startsAt.addingTimeInterval(-lead)
        if wanted > now { return wanted }
        guard now.timeIntervalSince(event.startsAt) <= grace else { return nil }
        // Just ahead of now, so the system has something in the future to fire.
        return now.addingTimeInterval(1)
    }

    /// One occurrence's own name, used as the notification's identifier.
    ///
    /// Adding a request whose identifier already exists replaces it, so this is
    /// what keeps one meeting to one prompt — by construction, with no list of
    /// "already asked" to keep in step with anything.
    ///
    /// The start time is in the key because a recurring event gives every
    /// occurrence the same identifier, and Monday's stand-up would otherwise
    /// silently replace Tuesday's. The hash is FNV-1a and **not** Swift's
    /// `hashValue`, which is seeded per process: an identifier built from that
    /// would change on every launch and re-schedule the lot.
    static func key(for event: MeetingEvent) -> String {
        let id = event.eventID ?? Names.normalise(event.title)
        return "calendar-\(Int(event.startsAt.timeIntervalSince1970))-\(stableHash(id))"
    }

    /// FNV-1a over UTF-8. Stable across launches and across machines, which is
    /// the only property wanted here.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}
