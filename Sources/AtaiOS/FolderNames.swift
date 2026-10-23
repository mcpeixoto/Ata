import Foundation

/// Meeting folder names, the same on iPhone as on the Mac:
/// "2026-10-23 14.02.05", plus the app when there is one ("… Call").
enum FolderNames {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        // Fixed, so a phone set to another calendar still sorts with the Mac's folders.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    static func name(startedAt: Date, app: String?) -> String {
        let base = formatter.string(from: startedAt)
        // App labels are words, but keep them from making a path.
        guard let app, !app.isEmpty else { return base }
        let safe = app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(base) \(safe)"
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
