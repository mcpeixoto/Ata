import Foundation

/// Ata on iPhone is free for five new meetings a calendar month; Ata Pro lifts
/// the limit. The Mac is free without any limit, and nothing here runs there.
///
/// What counts is a meeting this iPhone made: recorded (the button, Siri, the
/// Control, the Watch through the iPhone), imported from Files or the share
/// sheet, or recorded on the Watch and imported here. Meetings that came from
/// the Mac through iCloud, a transcript run again, and reading or exporting
/// never count.
///
/// A recording counts only once it has finished with audio and lasted at least
/// `minimumSeconds`. Anything shorter is a test tap: it is left out of the
/// library count and never written to the ledger. While it is still recording
/// its duration is unknown, and it counts, so it holds its place. An import
/// counts as soon as it lands, however long the file is — the ledger is written
/// then, and a short file already in the ledger still counts.
///
/// Two sources, so neither deleting a meeting nor reinstalling Ata gives one
/// back: the library (meetings whose origin is an iPhone and that started this
/// month) and a ledger of the meetings made this month, kept in the keychain.
/// The ledger also catches an import of an old file, whose meeting is dated
/// when the file was recorded.
enum FreeQuota {
    static let limit = 5
    /// A finished recording shorter than this did not use a free meeting.
    static let minimumSeconds = 30.0

    /// How many of this month's free meetings are used.
    /// - Parameters:
    ///   - ledger: meeting ids recorded for the month `now` is in.
    ///   - deviceID: this iPhone's id. Its own meetings from before devices had
    ///     a kind count too.
    static func used(meetings: [Meeting], ledger: Set<String>, now: Date = Date(),
                     calendar: Calendar = .current, deviceID: String? = nil) -> Int {
        var counted = ledger
        for m in meetings where madeOnAnIPhone(m, deviceID: deviceID)
            && calendar.isDate(m.startedAt, equalTo: now, toGranularity: .month)
            && countsInLibrary(m) {
            counted.insert(m.id)
        }
        return counted.count
    }

    /// Duration unknown (still recording) counts. A known length under
    /// `minimumSeconds` does not — unless the ledger already has the id,
    /// which is how a short import keeps counting.
    static func countsInLibrary(_ m: Meeting) -> Bool {
        guard let duration = m.duration else { return true }
        return duration >= minimumSeconds
    }

    /// Whether stopping a recording writes it to the keychain ledger.
    /// Imports do not come through here; they are recorded when they land.
    static func countsWhenStopped(duration: Double?, hasAudio: Bool) -> Bool {
        hasAudio && (duration ?? 0) >= minimumSeconds
    }

    static func remaining(used: Int) -> Int { max(0, limit - used) }

    static func madeOnAnIPhone(_ m: Meeting, deviceID: String?) -> Bool {
        guard let origin = m.origin, m.cloudPlaceholder != true else { return false }
        if let kind = origin.kind { return kind == DeviceRef.iPhone }
        return deviceID != nil && origin.id == deviceID
    }

    /// The keychain account for the month `date` is in: "quota-2026-10".
    static func account(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "quota-%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// The ledger as it is stored: one id a line. Meeting ids are folder names,
    /// which may hold a comma (an imported "Call, Bob.m4a") but never a newline
    /// (`FolderNames.safe`).
    static func decode(_ stored: String?) -> Set<String> {
        guard let stored else { return [] }
        return Set(stored.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: "\n")
    }
}
