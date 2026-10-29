import Foundation

/// Recordings made on the Apple Watch, as the iPhone receives them. Shared code
/// so the Mac's tests cover it; only the iPhone app calls it.
///
/// WatchConnectivity deletes a received file as soon as its delegate method
/// returns, so `keep` moves it into an inbox first, with its metadata. The
/// inbox copy is removed only once the recording is a meeting, and only then
/// is the Watch told it may delete its own copy. A file that can't be imported
/// stays in the inbox, and on the Watch, for the next try.
enum WatchImport {
    /// The meeting's app label, title and part of its folder name. A name, so
    /// the same in every language.
    static let app = "Apple Watch"

    enum Failure: LocalizedError {
        case noAudio

        var errorDescription: String? {
            switch self {
            case .noAudio: return L("There is no audio in this file.")
            }
        }
    }

    static var inbox: URL { Paths.supportDir.appendingPathComponent("Watch", isDirectory: true) }
    private static var ledgerURL: URL { inbox.appendingPathComponent("imported.json") }

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

    // MARK: Inbox

    /// Moves a received file into the inbox, next to its metadata. Must finish
    /// before WatchConnectivity's delegate method returns.
    static func keep(_ file: URL, info: WatchRecordingInfo) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let ext = file.pathExtension.isEmpty ? "wav" : file.pathExtension
        let audio = inbox.appendingPathComponent("\(info.id.uuidString).\(ext)")
        // The same recording sent again replaces the copy waiting for it.
        try? fm.removeItem(at: audio)
        do {
            try fm.moveItem(at: file, to: audio)
        } catch {
            try fm.copyItem(at: file, to: audio)
        }
        try encoder.encode(info).write(to: metaURL(for: info.id), options: .atomic)
    }

    private static func metaURL(for id: UUID) -> URL {
        inbox.appendingPathComponent("\(id.uuidString).json")
    }

    /// The recordings in the inbox, oldest first, with their audio.
    static func waiting() -> [(info: WatchRecordingInfo, audio: URL)] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles])) ?? []
        var found: [(info: WatchRecordingInfo, audio: URL)] = []
        for meta in files where meta.pathExtension == "json" && meta.lastPathComponent != ledgerURL.lastPathComponent {
            guard let data = try? Data(contentsOf: meta),
                  let info = try? decoder.decode(WatchRecordingInfo.self, from: data) else { continue }
            let name = info.id.uuidString
            guard let audio = files.first(where: {
                $0.deletingPathExtension().lastPathComponent == name && $0.pathExtension != "json"
            }) else { continue }
            found.append((info, audio))
        }
        return found.sorted { $0.info.startedAt < $1.info.startedAt }
    }

    /// Imports everything in the inbox and returns the recordings the Watch may
    /// now delete: the ones imported, and ones imported before and sent again.
    /// Runs one at a time, off the main thread.
    /// `imported` is told each new meeting's id, as it is made.
    static func importWaiting(imported: (String) -> Void = { _ in }) -> [UUID] {
        var ledger = Ledger.load(from: ledgerURL)
        var done: [UUID] = []
        for (info, audio) in waiting() {
            if ledger.meetingID(for: info.id) == nil {
                do {
                    let m = try meeting(from: audio, info: info)
                    ledger.record(info.id, meetingID: m.id)
                    ledger.save(to: ledgerURL)
                    imported(m.id)
                } catch {
                    NSLog("Ata: could not import the Watch recording \(info.id), kept for the next try: \(error.localizedDescription)")
                    continue
                }
            }
            try? FileManager.default.removeItem(at: audio)
            try? FileManager.default.removeItem(at: metaURL(for: info.id))
            done.append(info.id)
        }
        return done
    }

    // MARK: Meeting

    /// A new pending meeting from a Watch recording: dated when the Watch
    /// started recording, made by this device, with the Watch's bookmarks.
    /// Decoded in staging, like any recording, then moved into the meetings
    /// folder. The source is only read, except that a header left wrong by a
    /// recording cut short is corrected. A failure removes only the copy.
    static func meeting(from source: URL, info: WatchRecordingInfo) throws -> Meeting {
        // Before the first decode, not after a failed one: a header that still
        // holds an early size decodes fine, as a meeting missing its end, and
        // the Watch would then delete the whole recording. A no-op when the
        // sizes are right.
        repairSizes(source)
        var m = try Meeting.newImport(app: app, at: info.startedAt)
        do {
            guard try decode(source, into: m) else { throw Failure.noAudio }
            let duration = WavWriter.duration(of: m.micURL)
            m.duration = duration
            m.endedAt = info.startedAt.addingTimeInterval(duration)
            m.status = .pending
            if !info.bookmarks.isEmpty {
                m.bookmarks = info.bookmarks.sorted().map { Bookmark(ms: max(0, $0)) }
            }
            return try Library.finishImport(m)
        } catch {
            try? FileManager.default.removeItem(at: m.dir)
            throw error
        }
    }

    /// Whether decoding gave any audio.
    private static func decode(_ source: URL, into m: Meeting) throws -> Bool {
        try AudioFiles.decodeToWAV(source, to: m.micURL)
        return WavWriter.duration(of: m.micURL) > 0
    }

    /// A WAV whose recorder stopped before writing its final sizes (the Watch
    /// ran out of battery) says it holds less than it does. Sets the RIFF and
    /// data sizes from the file's length; the samples are left as they are.
    /// False when it isn't a WAV or its sizes are already right, which includes
    /// a WAV whose audio is followed by whole chunks of another kind (tags).
    @discardableResult
    static func repairSizes(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 12, size <= UInt64(UInt32.max) else { return false }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 64 * 1024), head.count >= 12,
              head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return false }

        func u32(_ at: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(head[at + i]) << (8 * UInt32(i)) }
            return v
        }
        func le(_ v: UInt32) -> Data {
            Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
        }

        var offset = 12
        while offset + 8 <= head.count {
            let id = head[offset..<offset + 4]
            let chunk = u32(offset + 4)
            if id == Data("data".utf8) {
                let start = UInt64(offset + 8)
                let declaredEnd = start + UInt64(chunk) + UInt64(chunk & 1)
                if chunk > 0, declaredEnd < size, endsInChunks(handle, from: declaredEnd, size: size) { return false }
                let dataBytes = UInt32((size - start) / 2 * 2)
                let riff = UInt32(size - 8)
                guard u32(4) != riff || chunk != dataBytes else { return false }
                do {
                    try handle.seek(toOffset: 4)
                    try handle.write(contentsOf: le(riff))
                    try handle.seek(toOffset: UInt64(offset + 4))
                    try handle.write(contentsOf: le(dataBytes))
                    try handle.synchronize()
                } catch {
                    return false
                }
                return true
            }
            offset += 8 + Int(chunk) + Int(chunk & 1)
        }
        return false
    }

    /// Whether what follows `offset` is whole chunks ending exactly at `size`.
    /// Audio past a stale data size almost never reads as one: a chunk id is
    /// four printable characters, and the lengths have to add up to the byte.
    private static func endsInChunks(_ handle: FileHandle, from offset: UInt64, size: UInt64) -> Bool {
        var at = offset
        var chunks = 0
        while at + 8 <= size, chunks < 64 {
            let bytes: [UInt8]
            do {
                try handle.seek(toOffset: at)
                let read = try handle.read(upToCount: 8)
                bytes = [UInt8](read ?? Data())
            } catch {
                return false
            }
            guard bytes.count == 8, bytes[0..<4].allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return false }
            var length: UInt64 = 0
            for i in 0..<4 { length |= UInt64(bytes[4 + i]) << (8 * UInt64(i)) }
            at += 8 + length + (length & 1)
            chunks += 1
        }
        return at == size
    }

    // MARK: Ledger

    /// The Watch recordings already imported, so one sent twice (its
    /// confirmation was lost, or the Watch sent it again after an hour without
    /// one) becomes one meeting.
    struct Ledger: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var id: UUID
            var meeting: String
        }

        /// Plenty for months of recordings; the oldest go first.
        static let limit = 500

        private(set) var entries: [Entry] = []

        func meetingID(for id: UUID) -> String? {
            entries.first { $0.id == id }?.meeting
        }

        mutating func record(_ id: UUID, meetingID: String) {
            entries.removeAll { $0.id == id }
            entries.append(Entry(id: id, meeting: meetingID))
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        }

        static func load(from url: URL) -> Ledger {
            guard let data = try? Data(contentsOf: url) else { return Ledger() }
            return (try? JSONDecoder().decode(Ledger.self, from: data)) ?? Ledger()
        }

        func save(to url: URL) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(self).write(to: url, options: .atomic)
            } catch {
                NSLog("Ata: could not save the list of imported Watch recordings: \(error.localizedDescription)")
            }
        }
    }
}
