import Foundation

struct Meeting: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case recording, pending, transcribing, done, failed
    }

    var id: String // nome da pasta
    var startedAt: Date
    var endedAt: Date?
    var duration: Double?
    var app: String?
    var status: Status
    var error: String?

    var dir: URL { Paths.meetingsDir.appendingPathComponent(id, isDirectory: true) }
    var metaURL: URL { dir.appendingPathComponent("meeting.json") }
    var transcriptURL: URL { dir.appendingPathComponent("transcricao.md") }
    var micURL: URL { dir.appendingPathComponent("mic.wav") }
    var systemURL: URL { dir.appendingPathComponent("system.wav") }

    var hasAudio: Bool {
        Paths.fileSize(micURL) > 44 || Paths.fileSize(systemURL) > 44
    }

    var title: String { app ?? "Meeting" }

    var subtitle: String {
        var parts = [Self.dayFormatter.string(from: startedAt)]
        if let duration, duration >= 1 {
            let m = Int((duration / 60).rounded())
            parts.append(m < 1 ? "<1 min" : "\(m) min")
        }
        return parts.joined(separator: " · ")
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_PT")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func new(app: String?) throws -> Meeting {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let now = Date()
        var m = Meeting(id: f.string(from: now), startedAt: now, endedAt: nil, duration: nil,
                        app: app, status: .recording, error: nil)
        if let app { m.id += " \(app)" }
        try FileManager.default.createDirectory(at: m.dir, withIntermediateDirectories: true)
        return m
    }
}

/// Lê e grava os metadados das meetings (meeting.json em cada pasta).
enum Library {
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

    static func save(_ m: Meeting) {
        do {
            try FileManager.default.createDirectory(at: m.dir, withIntermediateDirectories: true)
            try encoder.encode(m).write(to: m.metaURL, options: .atomic)
        } catch {
            NSLog("Ata: não consegui guardar \(m.id): \(error)")
        }
    }

    static func loadAll() -> [Meeting] {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.meetingsDir, withIntermediateDirectories: true)
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.meetingsDir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
                  var m = try? decoder.decode(Meeting.self, from: data) else { return nil }
            m.id = dir.lastPathComponent // a pasta pode ter sido renomeada
            return m
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    static func trash(_ m: Meeting) {
        try? FileManager.default.trashItem(at: m.dir, resultingItemURL: nil)
    }
}
