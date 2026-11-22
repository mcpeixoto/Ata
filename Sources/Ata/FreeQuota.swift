import Foundation

/// Each device is free for 300 minutes of new audio a calendar month. Ata Pro
/// lifts the limit on iPhone. The Mac has the same allowance and no purchase
/// yet, so past 300 a new recording or import waits until next month.
///
/// What counts is audio this device made. An iPhone counts its own recordings
/// and imports; a Mac counts its own. A meeting that arrived through iCloud
/// from the other device, a transcript run again, and reading or exporting
/// never count. A recording with no audio does not count. One that is still
/// recording has no duration yet and uses none of the allowance, so it is never
/// cut off; the next recording or import is what waits.
///
/// The screen shows whole minutes, rounded up on the month's total, so a few
/// leftover seconds still cost a minute and two short meetings share one rounding.
///
/// Two sources, so neither deleting a meeting nor reinstalling Ata gives the
/// minutes back: the library (meetings this device made that started this
/// month) and a ledger of the seconds used this month, kept in the keychain.
/// The ledger also catches an import of an old file, whose meeting is dated
/// when the file was recorded. A line written by an older Ata is just an id:
/// it is worth the duration still in the library, or nothing once deleted.
enum FreeQuota {
    /// Five hours, as a round number of minutes.
    static let limitMinutes = 300

    /// One stored meeting. `seconds` is nil on a line written before durations
    /// were kept: an id alone.
    struct Entry: Equatable {
        var seconds: Double?
    }

    /// How many of this month's free minutes are used, rounded up.
    /// - Parameters:
    ///   - ledger: meetings recorded for the month `now` is in.
    ///   - deviceID: this device's id. Its own meetings from before devices had
    ///     a kind count too.
    ///   - kind: `Device.kind`. iPhone and Mac each have their own 300 minutes.
    static func used(meetings: [Meeting], ledger: [String: Entry], now: Date = Date(),
                     calendar: Calendar = .current, deviceID: String? = nil,
                     kind: String) -> Int {
        var seconds = 0.0
        var charged = Set<String>()
        for (id, entry) in ledger {
            charged.insert(id)
            if let stored = entry.seconds {
                if stored > 0 { seconds += stored }
            } else if let meeting = meetings.first(where: { $0.id == id }) {
                seconds += countedSeconds(meeting)
            }
        }
        for meeting in meetings where !charged.contains(meeting.id)
            && madeHere(meeting, kind: kind, deviceID: deviceID)
            && calendar.isDate(meeting.startedAt, equalTo: now, toGranularity: .month) {
            seconds += countedSeconds(meeting)
        }
        return minutes(fromSeconds: seconds)
    }

    /// Whole minutes, rounded up on the total. Zero stays zero.
    static func minutes(fromSeconds seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return Int(ceil(seconds / 60))
    }

    /// A finished recording with audio uses its seconds. No audio does not.
    /// Imports do not come through here; they are recorded when they land.
    static func countsWhenStopped(duration: Double?, hasAudio: Bool) -> Bool {
        hasAudio && (duration ?? 0) > 0
    }

    static func remaining(used: Int) -> Int { max(0, limitMinutes - used) }

    /// A meeting this device made. One from the other device, or still a cloud
    /// placeholder, does not count. A meeting from before devices had a kind
    /// counts when its id is this device's.
    static func madeHere(_ m: Meeting, kind: String, deviceID: String?) -> Bool {
        guard let origin = m.origin, m.cloudPlaceholder != true else { return false }
        if let originKind = origin.kind { return originKind == kind }
        return deviceID != nil && origin.id == deviceID
    }

    /// The keychain account for the month `date` is in: "quota-2026-10".
    static func account(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "quota-%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// The ledger as it is stored, one meeting a line. `id` is a legacy line.
    /// `id<TAB>seconds` is the current line. Meeting ids are folder names, which
    /// may hold a comma (an imported "Call, Bob.m4a") but never a tab or a
    /// newline (`FolderNames.safe` turns both into spaces).
    static func decode(_ stored: String?) -> [String: Entry] {
        guard let stored else { return [:] }
        var entries: [String: Entry] = [:]
        for lineSub in stored.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(lineSub)
            if let tab = line.firstIndex(of: "\t") {
                let id = String(line[..<tab])
                let rest = String(line[line.index(after: tab)...])
                guard !id.isEmpty, let seconds = parseSeconds(rest) else { continue }
                entries[id] = Entry(seconds: seconds)
            } else {
                entries[line] = Entry(seconds: nil)
            }
        }
        return entries
    }

    static func encode(_ entries: [String: Entry]) -> String {
        entries.keys.sorted().map { id in
            guard let seconds = entries[id]?.seconds else { return id }
            return id + "\t" + formatSeconds(seconds)
        }.joined(separator: "\n")
    }

    /// A recording still going has no duration and uses none of the allowance.
    private static func countedSeconds(_ meeting: Meeting) -> Double {
        guard let duration = meeting.duration, duration > 0 else { return 0 }
        return duration
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private static func parseSeconds(_ text: String) -> Double? {
        let scanner = Scanner(string: text)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        guard let value = scanner.scanDouble(), scanner.isAtEnd, value >= 0 else { return nil }
        return value
    }
}
