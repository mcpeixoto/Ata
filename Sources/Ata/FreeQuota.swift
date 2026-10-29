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
/// Two sources, so neither deleting a meeting nor reinstalling Ata gives one
/// back: the library (meetings whose origin is an iPhone and that started this
/// month) and a ledger of the meetings made this month, kept in the keychain.
/// The ledger also catches an import of an old file, whose meeting is dated
/// when the file was recorded.
enum FreeQuota {
    static let limit = 5

    /// How many of this month's free meetings are used.
    /// - Parameters:
    ///   - ledger: meeting ids recorded for the month `now` is in.
    ///   - deviceID: this iPhone's id. Its own meetings from before devices had
    ///     a kind count too.
    static func used(meetings: [Meeting], ledger: Set<String>, now: Date = Date(),
                     calendar: Calendar = .current, deviceID: String? = nil) -> Int {
        var counted = ledger
        for m in meetings where madeOnAnIPhone(m, deviceID: deviceID)
            && calendar.isDate(m.startedAt, equalTo: now, toGranularity: .month) {
            counted.insert(m.id)
        }
        return counted.count
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
