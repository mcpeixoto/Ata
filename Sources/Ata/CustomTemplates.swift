import Foundation

/// A summary shape the user wrote. The five built-in templates stay as they are;
/// this is an extra one, and only Pro can have the model follow it.
struct CustomTemplate: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// At most `instructionLimit` characters. Longer text is cut, on purpose:
    /// the on-device window is small and a pasted page would crowd the transcript out.
    var instructions: String
    var sections: [String]

    static let instructionLimit = 1_000

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, sections
    }

    init(id: UUID = UUID(), name: String, instructions: String, sections: [String] = []) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.instructions = Self.capped(instructions)
        self.sections = sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func capped(_ text: String) -> String {
        String(text.prefix(instructionLimit))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let instructions = try container.decode(String.self, forKey: .instructions)
        let sections = try container.decodeIfPresent([String].self, forKey: .sections) ?? []
        self.init(id: id, name: name, instructions: instructions, sections: sections)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(instructions, forKey: .instructions)
        try container.encode(sections, forKey: .sections)
    }
}

/// What the summary is shaped by: one of the built-in templates, or a custom one.
enum TemplateChoice: Equatable {
    case builtIn(SummaryTemplate)
    case custom(CustomTemplate)

    /// A free user keeps every built-in template and cannot select a custom one.
    /// Call this before building a prompt.
    static func forUse(_ choice: TemplateChoice, isPro: Bool) -> TemplateChoice {
        if case .custom = choice, !isPro { return .builtIn(.standard) }
        return choice
    }
}

/// One device's templates and when they were saved, which is what iCloud compares.
struct TemplateSnapshot: Codable, Equatable {
    var savedAt: Date
    var templates: [CustomTemplate]
}

/// Where another device's copy of the templates is read and written. The app uses
/// the iCloud key-value store; tests hand back a fixed payload.
protocol TemplateCloudStore {
    func payload() -> (json: String, at: Date)?
    func write(json: String, at: Date)
}

/// `templates.json` in the support directory, and the same bytes in the iCloud
/// key-value store while sync is on. The store holds 1 MB for every key together
/// (`SettingsSync` already uses it), so a payload that would not fit is not written.
enum TemplateLibrary {
    static let fileName = "templates.json"
    static let cloudKey = "customTemplates"
    /// Half a megabyte. One key must not be the whole 1 MB the store allows.
    static let cloudByteLimit = 512_000

    enum Decision: Equatable {
        case keep
        case push
        case pull
    }

    static func file(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static var fileURL: URL { file(in: Paths.supportDir) }

    static func load(from directory: URL) -> [CustomTemplate] {
        snapshot(in: directory)?.templates ?? []
    }

    static func snapshot(in directory: URL) -> TemplateSnapshot? {
        guard let data = try? Data(contentsOf: file(in: directory)) else { return nil }
        return try? decoder.decode(TemplateSnapshot.self, from: data)
    }

    static func save(_ templates: [CustomTemplate], to directory: URL, at date: Date = Date()) throws {
        try write(TemplateSnapshot(savedAt: date, templates: templates), to: directory)
    }

    /// The templates on this device, and the cloud copy when iCloud sync is on.
    @MainActor
    static func save(_ templates: [CustomTemplate], at date: Date = Date()) throws {
        try save(templates, to: Paths.supportDir, at: date)
        TemplateSync.shared.localDidChange()
    }

    static func write(_ snapshot: TemplateSnapshot, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: file(in: directory), options: .atomic)
    }

    static func encode(_ snapshot: TemplateSnapshot) throws -> String {
        String(decoding: try encoder.encode(snapshot), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> TemplateSnapshot {
        try decoder.decode(TemplateSnapshot.self, from: Data(json.utf8))
    }

    /// Nil when `json` would not fit in the key-value store.
    static func cloudPayload(json: String, at: Date) -> [String: Any]? {
        guard json.utf8.count <= cloudByteLimit else { return nil }
        return ["v": json, "t": at.timeIntervalSince1970]
    }

    /// Same rule as the other synced settings: the later edit wins, and two
    /// copies of the same templates are left alone.
    static func decide(local: TemplateSnapshot?, remote: TemplateSnapshot?) -> Decision {
        switch (local, remote) {
        case (nil, nil):
            return .keep
        case (_?, nil):
            return .push
        case (nil, _?):
            return .pull
        case let (mine?, theirs?):
            if mine.templates == theirs.templates { return .keep }
            if theirs.savedAt > mine.savedAt { return .pull }
            if mine.savedAt > theirs.savedAt { return .push }
            return .keep
        }
    }

    static func reconcile(directory: URL, cloud: TemplateCloudStore, iCloudOn: Bool) throws {
        guard iCloudOn else { return }
        let local = snapshot(in: directory)
        let remote = try cloud.payload().map { try decode($0.json) }
        switch decide(local: local, remote: remote) {
        case .keep:
            break
        case .push:
            if let local { cloud.write(json: try encode(local), at: local.savedAt) }
        case .pull:
            if let remote { try write(remote, to: directory) }
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

struct UbiquitousTemplateCloud: TemplateCloudStore {
    func payload() -> (json: String, at: Date)? {
        // An ad-hoc Mac build has no ubiquity entitlement. The store then has
        // nothing under this key; it does not crash.
        guard let payload = NSUbiquitousKeyValueStore.default.dictionary(forKey: TemplateLibrary.cloudKey),
              let json = payload["v"] as? String, let stamp = payload["t"] as? Double else { return nil }
        return (json, Date(timeIntervalSince1970: stamp))
    }

    func write(json: String, at: Date) {
        guard let payload = TemplateLibrary.cloudPayload(json: json, at: at) else { return }
        let store = NSUbiquitousKeyValueStore.default
        store.set(payload, forKey: TemplateLibrary.cloudKey)
        store.synchronize()
    }
}

/// Pushes and pulls `templates.json` while meetings are kept in iCloud. Started
/// beside `SettingsSync`, and only then: the key-value store needs the entitlement.
@MainActor
final class TemplateSync {
    static let shared = TemplateSync()

    private var on = false
    private var observer: NSObjectProtocol?

    func update(on wanted: Bool) {
        guard wanted != on else { return }
        on = wanted
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard wanted else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default, queue: .main) { _ in
                MainActor.assumeIsolated { TemplateSync.shared.pull() }
            }
        _ = NSUbiquitousKeyValueStore.default.synchronize()
        pull()
    }

    func pull() {
        guard on else { return }
        try? TemplateLibrary.reconcile(directory: Paths.supportDir, cloud: UbiquitousTemplateCloud(), iCloudOn: true)
    }

    func localDidChange() {
        guard on, let snapshot = TemplateLibrary.snapshot(in: Paths.supportDir),
              let json = try? TemplateLibrary.encode(snapshot) else { return }
        UbiquitousTemplateCloud().write(json: json, at: snapshot.savedAt)
    }
}

/// The instructions the on-device model is given for one part of a conversation.
/// Built here, not inside the model session, so a test can read them.
enum SummaryPrompt {
    static func part(myName: String, choice: TemplateChoice, vocabulary: [String]) -> String {
        var text = """
        You take notes on one part of a recorded conversation between people who know each \
        other. It may be a work meeting, a planning session or a family phone call. \
        "\(myName)" is the person recording.

        The text comes from automatic speech recognition. Words can be wrong, speaker names \
        can be wrong, and sometimes only one side of a call was recorded. When a phrase makes \
        no sense, leave it out rather than guess what it meant. Never add an amount, date, \
        name or reason that is not in the text. Advice from one person is not a task for another.

        Write in \(Summarizer.replyLanguage). Speakers may use other languages; write about \
        what they said in that language anyway.
        """
        switch choice {
        case .builtIn(let template):
            if !template.focus.isEmpty { text += "\n\n" + template.focus }
        case .custom(let template):
            if !template.instructions.isEmpty { text += "\n\n" + template.instructions }
            if !template.sections.isEmpty {
                text += "\n\nOrganize the notes under these headings, in this order:\n"
                text += template.sections.map { "- \($0)" }.joined(separator: "\n")
            }
        }
        if let spelling = Vocabulary.spellingInstruction(vocabulary) { text += "\n\n" + spelling }
        if case .custom(let template) = choice, !template.sections.isEmpty {
            text += "\n\nReply with those headings in that order. Under each heading, short bullet points of what was actually said, in your own words. Leave out a heading the conversation did not cover. Never copy lines of the text."
        } else {
            text += "\n\nReply with one line saying the topic, then up to five short bullet points of what was actually said, in your own words. Never copy lines of the text."
        }
        return text
    }
}
