import Foundation

/// The iPhone's recordings are written into their own folder in staging
/// (`Device.stagingDir`) and only moved into the meetings folder once the audio
/// is closed. Whatever reads or syncs the meetings folder never sees a
/// half-written WAV.
///
/// Shared code so the Mac's tests cover it; only the iPhone calls it. Moving
/// out of staging, and recovering what a crash left there, are the Mac's own
/// `Library.moveIntoMeetings` and `Library.recoverStaged`.
enum StagingFolder {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// A new meeting, status `.recording`, with its staging folder created and
    /// its meeting.json written, so a crash mid-recording can be recovered.
    static func create(app: String?, at now: Date = Date()) throws -> (meeting: Meeting, folder: URL) {
        let id = try Library.makeFolder(named: FolderNames.name(startedAt: now, app: app), staged: true)
        let folder = Device.stagingDir.appendingPathComponent(id, isDirectory: true)
        var meeting = Meeting(id: id, startedAt: now, endedAt: nil, duration: nil,
                              app: app, status: .recording, error: nil)
        meeting.origin = Device.current
        do {
            try encoder.encode(meeting).write(to: folder.appendingPathComponent("meeting.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return (meeting, folder)
    }

    /// A recording that has stopped: its meeting.json saved in staging, then the
    /// folder moved into the meetings folder, and the meeting as it is now. If the
    /// move fails, `moved` is false and the folder stays in staging, where it is
    /// still listed and transcribed, until the next launch moves it.
    static func publish(_ m: Meeting) -> (meeting: Meeting, moved: Bool) {
        Library.save(m)
        do {
            let moved = try Library.moveIntoMeetings(m)
            return (moved, true)
        } catch {
            NSLog("Ata: could not move the recording out of staging: \(error.localizedDescription)")
            return (m, false)
        }
    }
}
