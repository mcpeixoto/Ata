import EventKit
import Foundation

/// Reading the user's calendar. The only file in Ata that knows `EKEvent` exists.
///
/// There is no write API in here, deliberately: EventKit has no read-only tier,
/// so Ata holds a permission wider than the feature, and the narrowness has to
/// come from the code instead. Adding a write would have to be a deliberate
/// edit, not a slip.
@MainActor
final class CalendarStore {
    static let shared = CalendarStore()

    /// One store for the process. Making a new `EKEventStore` per read drops the
    /// change notifications that tell Ata to look again.
    private let store = EKEventStore()

    /// The calendars Ata can see, for the picker in Settings.
    func calendars() -> [(id: String, title: String)] {
        guard CalendarAccess.isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map { (id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Everything on the calendar between now and the horizon, as the pure
    /// scheduler wants it.
    func upcoming(now: Date = Date(), horizon: TimeInterval = CalendarSchedule.horizon)
        -> [CalendarSchedule.Candidacy] {
        guard CalendarAccess.isAuthorized else { return [] }
        // From a little before now, so a meeting already under way is still
        // offered while it is inside the grace window.
        let from = now.addingTimeInterval(-CalendarSchedule.grace)
        let predicate = store.predicateForEvents(withStart: from, end: now.addingTimeInterval(horizon),
                                                 calendars: watched())
        return store.events(matching: predicate).compactMap(candidacy)
    }

    /// The event as the calendar has it now. A prompt scheduled an hour ago may
    /// be quoting a title that has since changed; this is how Record gets the
    /// current one. Nil when it cannot be found — the caller keeps its copy.
    func refresh(_ event: MeetingEvent) -> MeetingEvent? {
        guard CalendarAccess.isAuthorized, let id = event.eventID else { return nil }
        guard let found = store.calendarItems(withExternalIdentifier: id).compactMap({ $0 as? EKEvent })
            .min(by: { abs($0.startDate.timeIntervalSince(event.startsAt))
                     < abs($1.startDate.timeIntervalSince(event.startsAt)) }) else { return nil }
        return candidacy(found)?.event
    }

    /// Nil means every calendar Ata can read.
    private func watched() -> [EKCalendar]? {
        let wanted = Pref.d.string(forKey: Pref.calendarIDs)?
            .split(separator: ",").map(String.init) ?? []
        guard !wanted.isEmpty else { return nil }
        let chosen = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
        // Every chosen calendar has gone (an account was signed out): watch them
        // all rather than silently watching nothing.
        return chosen.isEmpty ? nil : chosen
    }

    private func candidacy(_ event: EKEvent) -> CalendarSchedule.Candidacy? {
        guard let meetingEvent = MeetingEvent(title: event.title ?? "",
                                              startsAt: event.startDate,
                                              endsAt: event.endDate,
                                              attendees: attendees(of: event),
                                              calendarName: event.calendar?.title,
                                              eventID: event.calendarItemExternalIdentifier) else { return nil }
        return CalendarSchedule.Candidacy(event: meetingEvent,
                                          isAllDay: event.isAllDay,
                                          isCancelled: event.status == .canceled,
                                          iDeclined: declined(event),
                                          isFree: event.availability == .free)
    }

    /// Whether the user said no — or nil when the calendar would not say.
    /// `isCurrentUser` is not reported by every account type, and treating
    /// "could not tell" as "declined" would silently drop real meetings.
    private func declined(_ event: EKEvent) -> Bool? {
        guard let attendees = event.attendees else { return nil }
        guard let me = attendees.first(where: \.isCurrentUser) else { return nil }
        return me.participantStatus == .declined
    }

    private func attendees(of event: EKEvent) -> [MeetingEvent.Attendee] {
        (event.attendees ?? []).compactMap { participant in
            let email = address(of: participant)
            // An invitation with only an address still has to show something
            // the user recognises.
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = (name?.isEmpty == false ? name : nil)
                ?? email.flatMap(Names.nameFromEmail)
            guard let shown, !shown.isEmpty else { return nil }
            return MeetingEvent.Attendee(name: shown, email: email, isMe: participant.isCurrentUser)
        }
    }

    /// EventKit has no email property: the address is in `URL`, as `mailto:…`.
    private func address(of participant: EKParticipant) -> String? {
        Names.normalise(email: participant.url.absoluteString)
    }
}
