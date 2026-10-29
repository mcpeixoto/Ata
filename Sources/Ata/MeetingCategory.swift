import Foundation

/// Work or personal: the one split most people want in a list of their meetings.
enum MeetingCategory: String, CaseIterable, Identifiable {
    case work, personal

    var id: String { rawValue }

    var name: String {
        switch self {
        case .work: return L("Work")
        case .personal: return L("Personal")
        }
    }

    var symbol: String {
        switch self {
        case .work: return "briefcase.fill"
        case .personal: return "house.fill"
        }
    }

    /// Apps people use for work calls, by the names `CoreAudioProbe` gives them.
    /// Lowercased, matched as a prefix so "Microsoft Teams" and "Teams" both count.
    private static let workApps = ["zoom", "teams", "microsoft teams", "slack", "webex", "around", "tuple", "google meet"]
    private static let personalApps = ["facetime", "whatsapp", "discord", "skype", "messenger"]

    /// The category a new meeting starts with, before anyone says otherwise.
    ///
    /// The calendar it came from wins, because the user said so in Settings.
    /// Then the app: Zoom is rarely a call with your mother, FaceTime rarely a
    /// stand-up. A browser could be either, so it says nothing. Last, the
    /// default the user picked, which may be none.
    ///
    /// `calendarName` is matched too, for an event whose identifier was not
    /// kept (meetings and prompts from before `MeetingEvent.calendarID`).
    static func guess(app: String?, calendarID: String?, calendarName: String?,
                      calendarMap: [String: String], default fallback: MeetingCategory?) -> MeetingCategory? {
        if let calendarID, let raw = calendarMap[calendarID], let c = MeetingCategory(rawValue: raw) { return c }
        if let calendarName, let raw = calendarMap[calendarName], let c = MeetingCategory(rawValue: raw) { return c }
        if let app = app?.lowercased().trimmingCharacters(in: .whitespaces), !app.isEmpty {
            if workApps.contains(where: { app.hasPrefix($0) }) { return .work }
            if personalApps.contains(where: { app.hasPrefix($0) }) { return .personal }
        }
        return fallback
    }

    /// `guess`, from what Settings holds. Nil when nothing points either way.
    static func initialTag(app: String?, event: MeetingEvent?, at date: Date = Date()) -> CategoryTag? {
        guard let c = guess(app: app, calendarID: event?.calendarID, calendarName: event?.calendarName,
                            calendarMap: calendarMap, default: defaultCategory) else { return nil }
        return CategoryTag(value: c.rawValue, manual: false, at: date)
    }

    /// What Settings says new meetings are, when nothing else does.
    static var defaultCategory: MeetingCategory? {
        Pref.d.string(forKey: Pref.defaultCategory).flatMap(MeetingCategory.init(rawValue:))
    }

    /// Calendar identifier (or, for older events, calendar name) → "work" | "personal".
    static var calendarMap: [String: String] {
        get { (Pref.d.dictionary(forKey: Pref.calendarCategories) as? [String: String]) ?? [:] }
        set { Pref.d.set(newValue, forKey: Pref.calendarCategories) }
    }

    /// The list filter: nil is every meeting.
    static func matches(_ m: Meeting, filter: String) -> Bool {
        guard let wanted = MeetingCategory(rawValue: filter) else { return true }
        return m.categoryValue == wanted
    }
}

/// A meeting's category as stored in meeting.json. The value is kept as text,
/// so a category a later Ata adds still reads (as no category) instead of
/// making the whole meeting unreadable. An empty value is a category the user
/// took away, kept with its date so an older copy of the meeting can't bring
/// it back.
struct CategoryTag: Codable, Equatable {
    var value: String
    /// Picked by the user, rather than guessed when the recording started.
    var manual: Bool
    var at: Date

    static func cleared(at date: Date = Date()) -> CategoryTag {
        CategoryTag(value: "", manual: true, at: date)
    }
}

extension Meeting {
    var categoryValue: MeetingCategory? { category.flatMap { MeetingCategory(rawValue: $0.value) } }
}
