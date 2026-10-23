import Foundation

/// Recordings are written into their own folder under `Paths.stagingDir` and only
/// moved into the meetings folder once the audio is closed. Whatever reads or
/// syncs the meetings folder never sees a half-written WAV.
enum StagingFolder {
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

    /// A new meeting, status `.recording`, with its staging folder created and
    /// its meeting.json written, so a crash mid-recording can be recovered.
    static func create(app: String?, at now: Date = Date()) throws -> (meeting: Meeting, folder: URL) {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.stagingDir, withIntermediateDirectories: true)
        let taken = Set((try? fm.contentsOfDirectory(atPath: Paths.stagingDir.path)) ?? [])
        let id = FolderNames.unique(FolderNames.name(startedAt: now, app: app), existing: taken)
        let folder = Paths.stagingDir.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let meeting = Meeting(id: id, startedAt: now, endedAt: nil, duration: nil,
                              app: app, status: .recording, error: nil)
        try writeMeta(meeting, in: folder)
        return (meeting, folder)
    }

    static func writeMeta(_ m: Meeting, in folder: URL) throws {
        try encoder.encode(m).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
    }

    static func readMeta(in folder: URL) -> Meeting? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meeting.json")) else { return nil }
        return try? decoder.decode(Meeting.self, from: data)
    }

    /// Moves a finished recording into the meetings folder and saves its
    /// meeting.json there. The id changes only if the name is already taken.
    static func publish(_ m: Meeting, from folder: URL) throws -> Meeting {
        let fm = FileManager.default
        try fm.createDirectory(at: Paths.meetingsDir, withIntermediateDirectories: true)
        let taken = Set((try? fm.contentsOfDirectory(atPath: Paths.meetingsDir.path)) ?? [])
        var m = m
        m.id = FolderNames.unique(m.id, existing: taken)
        try fm.moveItem(at: folder, to: m.dir)
        Library.save(m)
        return m
    }

    /// Folders left behind by a recording that never stopped (the app was ended,
    /// the phone ran out of battery). Their headers are repaired and they join the
    /// queue like any finished recording. A folder that can't be moved stays where
    /// it is, audio and all, for the next launch.
    static func recoverLeftovers(except current: URL?) -> [Meeting] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: Paths.stagingDir, includingPropertiesForKeys: [.creationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var recovered: [Meeting] = []
        for folder in folders where folder.standardizedFileURL != current?.standardizedFileURL {
            let seconds = WavWriter.repairHeader(folder.appendingPathComponent("mic.wav"))
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            var m = readMeta(in: folder)
                ?? Meeting(id: folder.lastPathComponent, startedAt: created, endedAt: nil, duration: nil,
                           app: nil, status: .recording, error: nil)
            m.id = folder.lastPathComponent
            m.duration = seconds
            m.endedAt = m.endedAt ?? m.startedAt.addingTimeInterval(seconds)
            m.status = seconds > 0 ? .pending : .failed
            if seconds <= 0 { m.error = L("Empty recording") }
            do {
                recovered.append(try publish(m, from: folder))
            } catch {
                NSLog("Ata: could not recover the recording in \(folder.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return recovered
    }
}
