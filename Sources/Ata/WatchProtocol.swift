import Foundation

// What Ata on the Apple Watch and Ata on the iPhone say to each other through
// WatchConnectivity, and the Watch's list of recordings still to hand over.
//
// Compiled into the Watch app, the iPhone app and the Mac's tests, so it is
// Foundation only. Every dictionary holds property-list values only (strings,
// numbers, dates, arrays), which is all WatchConnectivity carries.

private enum WatchKey {
    static let kind = "kind"
    static let version = "v"
    static let command = "command"
    static let state = "state"
    static let recording = "recording"
    static let imported = "imported"
    static let phase = "phase"
    static let recorded = "recorded"
    static let since = "since"
    static let bookmarks = "bookmarks"
    static let problem = "problem"
    static let detail = "detail"
    static let id = "id"
    static let startedAt = "startedAt"
    static let duration = "duration"
}

/// Numbers arrive as NSNumber after a trip through WatchConnectivity.
private func watchNumber(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    return (value as? NSNumber)?.doubleValue
}

private func watchIntegers(_ value: Any?) -> [Int]? {
    if let ints = value as? [Int] { return ints }
    guard let list = value as? [Any] else { return nil }
    let ints = list.compactMap { ($0 as? Int) ?? ($0 as? NSNumber)?.intValue }
    return ints.count == list.count ? ints : nil
}

// MARK: - Watch to iPhone

/// Something the Watch asks the iPhone to do. The iPhone answers each one with
/// its `WatchPhoneState`.
enum WatchCommand: String, CaseIterable, Equatable, Sendable {
    case start, stop, bookmark
    /// Carry on after an interruption the iPhone did not end by itself (a call
    /// that ended without iOS handing the microphone back).
    case resume
    /// Only the answer: what the iPhone is doing now.
    case state

    var message: [String: Any] {
        [WatchKey.kind: WatchKey.command, WatchKey.version: 1, WatchKey.command: rawValue]
    }

    init?(message: [String: Any]) {
        guard message[WatchKey.kind] as? String == WatchKey.command,
              let raw = message[WatchKey.command] as? String,
              let command = WatchCommand(rawValue: raw) else { return nil }
        self = command
    }
}

// MARK: - Timers

/// Recorded time that may be running: the seconds recorded until `since`, plus
/// the time since then while it runs. Paused (or not recording) it stands still.
struct WatchClock: Equatable, Sendable {
    var recorded: Double = 0
    /// When it last started running; nil while it stands still.
    var since: Date? = nil

    var isRunning: Bool { since != nil }

    func elapsed(at now: Date) -> Double {
        recorded + (since.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Where a counting-up timer would start from, so it shows `elapsed`; nil
    /// when the clock stands still.
    var timerStart: Date? {
        since.map { $0.addingTimeInterval(-recorded) }
    }

    mutating func run(at now: Date) {
        guard since == nil else { return }
        since = now
    }

    mutating func pause(at now: Date) {
        recorded = elapsed(at: now)
        since = nil
    }
}

enum WatchFormat {
    /// "0:05", "12:34", "1:02:03": a recording's length on a small screen.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - iPhone to Watch

/// What the iPhone is doing, as the Watch shows it. Sent as the application
/// context after every change, and as the answer to every command.
struct WatchPhoneState: Equatable, Sendable {
    enum Phase: String, Sendable {
        case idle, starting, recording, interrupted, stopping
    }

    /// Why the iPhone did not do what the Watch asked.
    enum Problem: String, Sendable {
        /// iOS does not let an app turn the microphone on from the background
        /// when asked from the Watch: Ata has to be opened on the iPhone.
        case openPhone
        /// Ata on the iPhone has not been allowed to use the microphone.
        case microphone
        /// Recording could not start; `detail` says why, in the iPhone's words.
        case failed
    }

    var phase: Phase
    var clock: WatchClock
    var bookmarks: Int
    var problem: Problem? = nil
    var detail: String? = nil

    var isActive: Bool { phase == .recording || phase == .interrupted }

    /// `recorded` seconds of audio at `now`; the clock runs only while recording.
    init(phase: Phase, recorded: Double, at now: Date, bookmarks: Int,
         problem: Problem? = nil, detail: String? = nil) {
        self.phase = phase
        clock = WatchClock(recorded: max(0, recorded), since: phase == .recording ? now : nil)
        self.bookmarks = bookmarks
        self.problem = problem
        self.detail = detail
    }

    static let idle = WatchPhoneState(phase: .idle, recorded: 0, at: Date(), bookmarks: 0)

    var dictionary: [String: Any] {
        var d: [String: Any] = [WatchKey.kind: WatchKey.state, WatchKey.version: 1, WatchKey.phase: phase.rawValue,
                                WatchKey.recorded: clock.recorded, WatchKey.bookmarks: bookmarks]
        if let since = clock.since { d[WatchKey.since] = since }
        if let problem { d[WatchKey.problem] = problem.rawValue }
        if let detail { d[WatchKey.detail] = detail }
        return d
    }

    init?(dictionary d: [String: Any]) {
        guard d[WatchKey.kind] as? String == WatchKey.state,
              let raw = d[WatchKey.phase] as? String, let phase = Phase(rawValue: raw),
              let recorded = watchNumber(d[WatchKey.recorded]) else { return nil }
        self.phase = phase
        clock = WatchClock(recorded: max(0, recorded), since: d[WatchKey.since] as? Date)
        bookmarks = watchNumber(d[WatchKey.bookmarks]).map { Int($0) } ?? 0
        problem = (d[WatchKey.problem] as? String).flatMap(Problem.init(rawValue:))
        detail = d[WatchKey.detail] as? String
    }
}

// MARK: - Recordings made on the Watch

/// What travels with a recording made on the Watch, as the file transfer's
/// metadata. The id lets the iPhone recognise a file it has already imported.
struct WatchRecordingInfo: Codable, Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    /// Seconds, as the Watch counted them. The iPhone measures the file itself.
    var duration: Double
    /// Moments marked while recording, in ms from the start.
    var bookmarks: [Int]

    var metadata: [String: Any] {
        [WatchKey.kind: WatchKey.recording, WatchKey.version: 1, WatchKey.id: id.uuidString,
         WatchKey.startedAt: startedAt, WatchKey.duration: duration, WatchKey.bookmarks: bookmarks]
    }

    init(id: UUID = UUID(), startedAt: Date, duration: Double = 0, bookmarks: [Int] = []) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.bookmarks = bookmarks
    }

    init?(metadata: [String: Any]?) {
        guard let m = metadata, m[WatchKey.kind] as? String == WatchKey.recording,
              let raw = m[WatchKey.id] as? String, let id = UUID(uuidString: raw),
              let startedAt = m[WatchKey.startedAt] as? Date else { return nil }
        self.id = id
        self.startedAt = startedAt
        duration = max(0, watchNumber(m[WatchKey.duration]) ?? 0)
        bookmarks = watchIntegers(m[WatchKey.bookmarks]) ?? []
    }
}

/// The iPhone saying it has a Watch recording safely in its meetings: only
/// then does the Watch delete its copy. Sent with `transferUserInfo`, which
/// WatchConnectivity delivers even if the Watch app isn't running.
enum WatchAck {
    static func message(for id: UUID) -> [String: Any] {
        [WatchKey.kind: WatchKey.imported, WatchKey.version: 1, WatchKey.id: id.uuidString]
    }

    static func id(from userInfo: [String: Any]) -> UUID? {
        guard userInfo[WatchKey.kind] as? String == WatchKey.imported,
              let raw = userInfo[WatchKey.id] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}

/// The Watch's recordings that the iPhone doesn't have yet, kept on disk next
/// to them. A recording leaves this list, and its file the Watch, only through
/// `confirmed`, when the iPhone says it has imported it: a finished transfer
/// only means the file reached the iPhone, not that the iPhone kept it.
struct WatchOutbox: Codable, Equatable {
    struct Item: Codable, Equatable {
        enum State: String, Codable {
            /// Not handed to WatchConnectivity yet, or its transfer failed.
            case waiting
            /// WatchConnectivity is transferring it.
            case sending
            /// It reached the iPhone; waiting for the iPhone to confirm the import.
            case delivered
        }

        var info: WatchRecordingInfo
        /// The file's name in the Watch's recordings folder.
        var file: String
        var state: State = .waiting
        /// When `state` last changed.
        var changedAt: Date? = nil

        var id: UUID { info.id }
    }

    /// A delivered recording the iPhone hasn't confirmed after this long is sent
    /// again; the iPhone recognises it and only confirms.
    static let confirmationTimeout: TimeInterval = 60 * 60

    private(set) var items: [Item] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func add(_ info: WatchRecordingInfo, file: String) {
        guard !items.contains(where: { $0.id == info.id }) else { return }
        items.append(Item(info: info, file: file))
    }

    /// The recordings to hand to WatchConnectivity now, marked as sending:
    /// ones waiting, ones whose transfer WatchConnectivity no longer has
    /// (`inFlight` is what it is still transferring), and delivered ones the
    /// iPhone never confirmed.
    mutating func due(at now: Date, inFlight: Set<UUID>) -> [Item] {
        var due: [Item] = []
        for i in items.indices {
            let item = items[i]
            let send: Bool
            switch item.state {
            case .waiting:
                send = true
            case .sending:
                send = !inFlight.contains(item.id)
            case .delivered:
                send = now.timeIntervalSince(item.changedAt ?? .distantPast) > Self.confirmationTimeout
            }
            guard send else { continue }
            items[i].state = .sending
            items[i].changedAt = now
            due.append(items[i])
        }
        return due
    }

    /// WatchConnectivity finished a transfer. Never removes anything: a failed
    /// one waits to be sent again, a delivered one for the iPhone's confirmation.
    mutating func transferFinished(_ id: UUID, failed: Bool, at now: Date) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = failed ? .waiting : .delivered
        items[i].changedAt = now
    }

    /// The iPhone has imported the recording: it leaves the list, and the
    /// caller may delete the returned item's file. Nil for one not in the list.
    mutating func confirmed(_ id: UUID) -> Item? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: i)
    }

    /// A file that is no longer there can't be sent: forget it.
    mutating func forget(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}
