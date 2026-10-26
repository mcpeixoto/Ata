import Foundation

/// The calendar event a meeting was recorded for.
///
/// A copy, not a link. The calendar belongs to the user: an event gets renamed,
/// moved or deleted, and a whole account can be signed out — a transcript still
/// has to say what the meeting was and who was asked to it. Nothing here is ever
/// sent anywhere; the names are other people's, and they stay on the device, or
/// in the user's own iCloud with the meetings.
struct MeetingEvent: Codable, Equatable {
    /// The event's title, trimmed and never empty: the meeting's name, in the
    /// folder name and at the top of the transcript.
    var title: String
    /// When the event was due to start, which is not when recording did — a
    /// prompt a minute early and a tap five minutes late both land here.
    var startsAt: Date
    var endsAt: Date? = nil
    /// Everyone on the invitation, you included, in the order the calendar gave
    /// them. Capped at `attendeeLimit`; `attendeeTotal` says how many there
    /// really were, so an all-hands reads as "and 180 others" instead of putting
    /// two hundred names in a meeting.json that syncs to every device.
    var attendees: [Attendee] = []
    var attendeeTotal: Int? = nil
    /// The calendar it sits in ("Work", "miguel@gmail.com"), so a meeting can
    /// say where its title came from when two accounts both have something at ten.
    var calendarName: String? = nil
    /// How to find the event again when the user taps Record and the title has
    /// changed since the prompt was scheduled. Nil when EventKit gave none.
    var eventID: String? = nil

    /// Beyond this many people, only the first this many are kept.
    static let attendeeLimit = 40

    /// One person on an invitation.
    struct Attendee: Codable, Equatable, Identifiable {
        /// The name the calendar had, trimmed. Never empty: an invitation with
        /// only an address keeps the part before the @, which is what the user
        /// would recognise anyway.
        var name: String
        /// Their address, when the invitation carried one. The one handle a
        /// person keeps across a change of name, and what tells two Ritas apart.
        var email: String? = nil
        /// You. Your own row is never offered as an answer to "Who's this?".
        /// False when Ata could not tell: a suggestion the user ignores costs a
        /// glance, and guessing wrong here would hide the right answer.
        var isMe: Bool = false

        var id: String { email ?? name }
    }

    /// Everyone but you.
    var others: [Attendee] { attendees.filter { !$0.isMe } }

    /// Trimmed, capped and only if there is a title left to keep. The one way a
    /// `MeetingEvent` is made, so a blank or whitespace-only title never becomes
    /// a meeting called "".
    init?(title: String, startsAt: Date, endsAt: Date? = nil, attendees: [Attendee] = [],
          attendeeTotal: Int? = nil, calendarName: String? = nil, eventID: String? = nil) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        self.title = name
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.attendees = Array(attendees.prefix(Self.attendeeLimit))
        self.attendeeTotal = attendeeTotal ?? (attendees.count > Self.attendeeLimit ? attendees.count : nil)
        self.calendarName = calendarName
        self.eventID = eventID
    }
}

/// A `MeetingEvent` as a string, because a notification's `userInfo` has to be
/// plist-serialisable and this travels in one — the prompt is scheduled long
/// before the user taps Record, and the event has to come back with it.
enum MeetingEventCoding {
    static func json(_ event: MeetingEvent) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func event(_ json: String?) -> MeetingEvent? {
        guard let json, !json.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingEvent.self, from: Data(json.utf8))
    }
}
