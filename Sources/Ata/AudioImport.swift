import Foundation
import UniformTypeIdentifiers

/// Turns an audio file into a meeting: decoded into the 16 kHz mono track
/// the engines read, in a new folder of its own.
///
/// Shared by the Mac (drop on the menu, "Import audio…") and the iPhone (Files,
/// "Open in Ata", the share sheet), so no AppKit or UIKit here.
enum AudioImport {
    enum Failure: LocalizedError {
        case noAudio

        var errorDescription: String? {
            switch self {
            case .noAudio: return L("There is no audio in this file.")
            }
        }
    }

    /// Anything the system can decode as audio.
    static let types: [UTType] = [.audio]

    static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    /// A new pending meeting made from `source`, named after the file and dated
    /// when it was made. Decoded in staging, like a recording, then moved into
    /// the meetings folder. A failure removes only the copy being written.
    ///
    /// `name` and `date` stand in for the file's own when `source` is a copy
    /// (the iPhone's share inbox), whose name and dates are the copy's.
    static func meeting(from source: URL, named name: String? = nil, at date: Date? = nil) throws -> Meeting {
        let date = date ?? recordedDate(of: source)
        let titled = name.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? source
        var m = try Meeting.new(app: label(for: titled), at: date, staged: true)
        do {
            try AudioFiles.decodeToWAV(source, to: m.micURL)
            guard WavWriter.duration(of: m.micURL) > 0 else { throw Failure.noAudio }
        } catch {
            try? FileManager.default.removeItem(at: m.dir)
            throw error
        }
        let duration = WavWriter.duration(of: m.micURL)
        m.duration = duration
        m.endedAt = date.addingTimeInterval(duration)
        m.status = .pending
        Library.save(m)
        return Library.publish(m)
    }

    /// When the file was made, as far as it says: a copied file can be newer
    /// than the recording, so the earliest date is the closest.
    static func recordedDate(of source: URL) -> Date {
        let values = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.min() ?? Date()
    }

    /// The file's name, made safe for a folder name.
    static func label(for source: URL) -> String {
        let name = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? L("Imported") : String(name.prefix(60))
    }
}
