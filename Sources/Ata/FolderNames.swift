import Foundation

/// Meeting folder names, the same on iPhone as on the Mac:
/// "2026-10-23 14.02.05", plus what the meeting is called when there is
/// something to call it ("… Weekly sync", "… Call").
enum FolderNames {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Fixed, so a phone set to another calendar still sorts with the Mac's folders.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    static func name(startedAt: Date, app: String?, event: MeetingEvent? = nil) -> String {
        let base = formatter.string(from: startedAt)
        guard let label = safe(label(app: app, event: event)) else { return base }
        return "\(base) \(label)"
    }

    /// What goes after the timestamp: the calendar event's title when the meeting
    /// came from one, otherwise the app. The same order as `Meeting.title`, so a
    /// folder and the window that opens it never disagree.
    static func label(app: String?, event: MeetingEvent?) -> String? {
        event?.title ?? app
    }

    /// A folder-safe one-liner, or nil when nothing legible is left.
    ///
    /// App names came from the system and only ever needed `/` and `:` taken out.
    /// An event title is whatever the user typed into Calendar: it can hold
    /// newlines, control characters, a leading dot that would hide the folder,
    /// emoji (kept — their title is their title), and any length at all. A path
    /// component caps at 255 bytes on APFS, and `Library.makeFolder` passes the
    /// name straight to `createDirectory`, which throws on a longer one — inside
    /// `startRecording`, where a throw means no recording. Hence the cap, with
    /// room left for the timestamp in front and the " 2", " 3"… a collision adds.
    ///
    /// Truncation counts whole characters, so it never cuts a scalar in half and
    /// never leaves invalid UTF-8 behind.
    static func safe(_ label: String?, maxBytes: Int = 180) -> String? {
        guard let label else { return nil }
        var out = ""
        for character in label {
            if character == "/" || character == ":" {
                out.append("-")
            } else if character.isNewline || character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                out.append(" ")
            } else {
                out.append(character)
            }
        }
        // One space between words, whatever arrived.
        out = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while out.utf8.count > maxBytes, !out.isEmpty { out.removeLast() }
        // A leading dot would hide the folder; a trailing dash or space reads as a slip.
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        guard !out.isEmpty, out != ".", out != ".." else { return nil }
        return out
    }

    /// `name`, or "name 2", "name 3"… when it is taken: two recordings started in the
    /// same second, or one recovered next to a folder that already has its name.
    static func unique(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        var n = 2
        while existing.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }
}
