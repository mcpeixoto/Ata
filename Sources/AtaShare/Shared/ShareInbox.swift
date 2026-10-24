import Foundation

// Compiled into the iPhone app, the share extension and the iPhone tests, so
// Foundation only: no Meeting, no L(), nothing of the app's.

/// One shared audio file waiting in the inbox, as its JSON sidecar says.
struct InboxItem: Codable, Equatable, Sendable {
    /// The copy's file name in the inbox folder.
    var file: String
    /// The name it had where it was shared from; the meeting is named after it.
    var originalName: String
    /// When it was recorded, as far as the file said, or else when it was shared.
    var date: Date
    /// Times the app tried to make a meeting of it and could not.
    var attempts: Int

    init(file: String, originalName: String, date: Date, attempts: Int = 0) {
        self.file = file
        self.originalName = originalName
        self.date = date
        self.attempts = attempts
    }

    private enum CodingKeys: String, CodingKey { case file, originalName, date, attempts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        originalName = try c.decode(String.self, forKey: .originalName)
        date = try c.decode(Date.self, forKey: .date)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
    }
}

/// An item and where its two files are.
struct InboxEntry: Equatable, Sendable {
    var item: InboxItem
    var audio: URL
    var sidecar: URL
}

/// Audio shared to Ata from another app (Voice Memos, Files, Mail, a chat).
///
/// The share extension can't make meetings or run the transcription queue, so it
/// only copies each file into the app group's Inbox folder, with a sidecar
/// `<file>.json` written last. The app turns each one into a meeting when it
/// opens, and removes the copy only once that meeting exists: audio is never
/// deleted on a failure.
enum ShareInbox {
    static let appGroup = "group.ai.interactive.ata"
    /// The most files one share adds. The extension's activation rule says the same.
    static let maxFiles = 10
    /// After this many failed imports an item is left alone, kept, instead of
    /// failing again every time Ata opens.
    static let maxAttempts = 3

    /// Inbox in the container the app and the extension share. Nil without the
    /// app group entitlement (an unsigned build): then there is no inbox.
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func encode(_ item: InboxItem) throws -> Data {
        try encoder.encode(item)
    }

    static func decode(_ data: Data) throws -> InboxItem {
        try decoder.decode(InboxItem.self, from: data)
    }

    static func sidecarName(for file: String) -> String {
        file + ".json"
    }

    /// The name to title the meeting with: the one the sharing app suggests,
    /// with the file's extension, or the file's own. Never a path.
    static func originalName(suggested: String?, file: URL) -> String {
        let fallback = file.lastPathComponent
        guard let suggested = suggested?
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !suggested.isEmpty else { return fallback }
        let ext = file.pathExtension
        if ext.isEmpty || (suggested as NSString).pathExtension.lowercased() == ext.lowercased() { return suggested }
        return suggested + "." + ext
    }

    // MARK: Adding (the share extension)

    /// Copies `source` into `folder` under a new name. The source is only read.
    /// The audio is copied first and the sidecar written last, atomically, so
    /// the app never picks up a file that is still being copied.
    @discardableResult
    static func add(_ source: URL, originalName: String, date: Date, to folder: URL) throws -> InboxItem {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let ext = source.pathExtension
        let file = ext.isEmpty ? id : "\(id).\(ext)"
        let audio = folder.appendingPathComponent(file)
        try fm.copyItem(at: source, to: audio)
        let item = InboxItem(file: file, originalName: originalName, date: date)
        do {
            try encode(item).write(to: folder.appendingPathComponent(sidecarName(for: file)), options: .atomic)
        } catch {
            // Only the copy just made; the shared file itself is untouched.
            try? fm.removeItem(at: audio)
            throw error
        }
        return item
    }

    // MARK: Draining (the app)

    /// Whole items still to import, oldest first. Skipped: a sidecar that can't
    /// be read or names another file, one whose audio is missing, and one that
    /// failed `maxAttempts` times.
    static func pending(in folder: URL) -> [InboxEntry] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var entries: [InboxEntry] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let sidecar = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: sidecar),
                  let item = try? decode(data),
                  sidecarName(for: item.file) == name,
                  item.attempts < maxAttempts else { continue }
            let audio = folder.appendingPathComponent(item.file)
            guard fm.fileExists(atPath: audio.path) else { continue }
            entries.append(InboxEntry(item: item, audio: audio, sidecar: sidecar))
        }
        return ordered(entries)
    }

    /// Oldest first, as they were recorded; same-second files by name.
    static func ordered(_ entries: [InboxEntry]) -> [InboxEntry] {
        entries.sorted {
            if $0.item.date != $1.item.date { return $0.item.date < $1.item.date }
            if $0.item.originalName != $1.item.originalName { return $0.item.originalName < $1.item.originalName }
            return $0.item.file < $1.item.file
        }
    }

    struct Report: Equatable, Sendable {
        struct Failure: Equatable, Sendable {
            var name: String
            var message: String
        }

        /// Original names of the files that became meetings, in order.
        var imported: [String] = []
        var failed: [Failure] = []
    }

    /// Hands each entry to `importOne`, oldest first. An entry's files are
    /// removed only after `importOne` returned; when it throws they stay, with
    /// one more attempt counted in the sidecar, and the next entry goes on.
    static func drain(_ entries: [InboxEntry], importing importOne: (InboxEntry) throws -> Void) -> Report {
        var report = Report()
        for entry in ordered(entries) {
            do {
                try importOne(entry)
            } catch {
                var item = entry.item
                item.attempts += 1
                if let data = try? encode(item) { try? data.write(to: entry.sidecar, options: .atomic) }
                report.failed.append(Report.Failure(name: item.originalName, message: error.localizedDescription))
                continue
            }
            remove(entry)
            report.imported.append(entry.item.originalName)
        }
        return report
    }

    /// The sidecar goes first: if Ata stops in between, the leftover audio has
    /// no sidecar and is never imported twice.
    static func remove(_ entry: InboxEntry) {
        let fm = FileManager.default
        try? fm.removeItem(at: entry.sidecar)
        try? fm.removeItem(at: entry.audio)
    }
}
