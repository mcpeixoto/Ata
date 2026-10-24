import Foundation
import WatchConnectivity

/// Everything the Watch app shows and does.
///
/// With the iPhone in reach, the buttons control Ata on the iPhone, which
/// records. Out of reach (or when the iPhone can't start), the Watch records by
/// itself and hands the file to the iPhone afterwards with
/// `WCSession.transferFile`. Its copy is deleted only when the iPhone confirms
/// the recording is one of its meetings; until then it stays in the outbox and
/// is sent again as needed.
@MainActor
final class WatchModel: ObservableObject {
    static let shared = WatchModel()

    enum Notice: Equatable {
        /// iOS didn't let Ata start in the background.
        case openPhone
        /// Ata on the iPhone may not use the microphone yet.
        case phoneMicrophone
        /// The iPhone didn't answer.
        case noAnswer
        /// Something else went wrong, in the words of the iPhone or this Watch.
        case failed(String)
    }

    /// What the iPhone said last; only acted on while it is reachable.
    @Published private(set) var phone = WatchPhoneState.idle
    @Published private(set) var reachable = false
    /// Waiting for the iPhone to answer a button.
    @Published private(set) var waiting = false
    @Published private(set) var notice: Notice?
    /// Recordings made here that the iPhone hasn't confirmed yet.
    @Published private(set) var unsent = 0
    /// Bumped when the Watch's own recording changes, to redraw.
    @Published private(set) var localRevision = 0

    let recorder: WatchRecorder
    private let delegate = WatchSessionDelegate()
    private var outbox = WatchOutbox()
    private var activated = false
    private var startingLocally = false

    private static let folder: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Recordings", isDirectory: true)
    private static var outboxURL: URL { folder.appendingPathComponent("outbox.json") }

    private init() {
        recorder = WatchRecorder(folder: Self.folder)
        recorder.onChange = { [weak self] in self?.localRevision += 1 }
        recorder.onEndedBySystem = { [weak self] in self?.stopLocal() }
    }

    // MARK: What to show

    /// Recording here, on this Watch.
    var isRecordingHere: Bool { recorder.isActive }
    /// Recording on the iPhone, as far as the Watch can tell.
    var isRecordingOnPhone: Bool { !isRecordingHere && reachable && phone.isActive }
    var isRecording: Bool { isRecordingHere || isRecordingOnPhone }
    /// The iPhone was recording when it went out of reach.
    var phoneMayBeRecording: Bool { !isRecordingHere && !reachable && phone.isActive }

    var isPaused: Bool {
        isRecordingHere ? recorder.state.phase == .interrupted : isRecordingOnPhone && phone.phase == .interrupted
    }

    var clock: WatchClock {
        if isRecordingHere { return recorder.clock }
        if isRecordingOnPhone { return phone.clock }
        return WatchClock()
    }

    var bookmarkCount: Int {
        isRecordingHere ? recorder.bookmarks.count : (isRecordingOnPhone ? phone.bookmarks : 0)
    }

    var isBusy: Bool {
        waiting || startingLocally || (reachable && (phone.phase == .starting || phone.phase == .stopping))
    }

    // MARK: Launch

    func activate() {
        guard !activated else { return }
        activated = true
        loadOutbox()
        // A recording cut short last time is sent like any other.
        if let leftover = recorder.leftover() {
            outbox.add(leftover.info, file: leftover.file)
            saveOutbox()
        }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    func becameActive() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        sessionChanged(reachable: session.isReachable)
        if let state = WatchPhoneState(dictionary: session.receivedApplicationContext) { phone = state }
        if reachable { ask(.state) }
        sendOutbox()
    }

    // MARK: Buttons

    func recordTapped() {
        notice = nil
        if isRecordingHere {
            stopLocal()
        } else if isRecordingOnPhone {
            ask(.stop)
        } else if reachable {
            ask(.start)
        } else {
            startLocal()
        }
    }

    func bookmarkTapped() {
        if isRecordingHere {
            recorder.bookmark()
        } else if isRecordingOnPhone {
            ask(.bookmark)
        }
    }

    func resumeTapped() {
        if isRecordingHere { recorder.resume() }
    }

    /// After the iPhone couldn't start: record here instead.
    func recordHere() {
        notice = nil
        startLocal()
    }

    // MARK: The iPhone

    private func ask(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            if command == .start { notice = .noAnswer }
            return
        }
        waiting = true
        Self.send(command, on: session)
    }

    /// Off the main actor: WatchConnectivity calls the handlers on its own queue.
    nonisolated private static func send(_ command: WatchCommand, on session: WCSession) {
        session.sendMessage(command.message, replyHandler: { reply in
            let state = WatchPhoneState(dictionary: reply)
            Task { @MainActor in WatchModel.shared.answered(command, with: state) }
        }, errorHandler: { error in
            let text = error.localizedDescription
            Task { @MainActor in WatchModel.shared.failed(command, text) }
        })
    }

    private func answered(_ command: WatchCommand, with state: WatchPhoneState?) {
        waiting = false
        guard let state else { return }
        phone = state
        switch state.problem {
        case .openPhone?: notice = .openPhone
        case .microphone?: notice = .phoneMicrophone
        case .failed?: notice = .failed(state.detail ?? L("The recording could not start."))
        case nil: break
        }
    }

    private func failed(_ command: WatchCommand, _ text: String) {
        waiting = false
        NSLog("Ata: the iPhone did not answer \(command.rawValue): \(text)")
        if command == .start { notice = .noAnswer }
    }

    fileprivate func received(_ state: WatchPhoneState) {
        phone = state
    }

    fileprivate func sessionChanged(reachable: Bool) {
        self.reachable = reachable
        if reachable { sendOutbox() }
    }

    // MARK: Recording here

    private func startLocal() {
        guard !isRecordingHere, !startingLocally else { return }
        startingLocally = true
        Task {
            defer { startingLocally = false }
            do {
                try await recorder.start()
            } catch {
                notice = .failed(error.localizedDescription)
            }
        }
    }

    private func stopLocal() {
        guard let finished = recorder.stop() else { return }
        outbox.add(finished.info, file: finished.file)
        saveOutbox()
        sendOutbox()
    }

    // MARK: Outbox

    /// Hands what is due to WatchConnectivity, which keeps transferring with
    /// Ata closed and delivers when the iPhone is in reach.
    func sendOutbox() {
        let session = WCSession.default
        guard session.activationState == .activated, !outbox.isEmpty else { return }
        let inFlight = Set(session.outstandingFileTransfers.compactMap { WatchRecordingInfo(metadata: $0.file.metadata)?.id })
        var changed = false
        for item in outbox.due(at: Date(), inFlight: inFlight) {
            changed = true
            let url = Self.folder.appendingPathComponent(item.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                NSLog("Ata: the Watch recording \(item.id) is no longer here")
                outbox.forget(item.id)
                continue
            }
            _ = session.transferFile(url, metadata: item.info.metadata)
        }
        if changed { saveOutbox() }
    }

    fileprivate func transferFinished(_ id: UUID, error: String?) {
        if let error { NSLog("Ata: sending the Watch recording \(id) failed, kept to send again: \(error)") }
        outbox.transferFinished(id, failed: error != nil, at: Date())
        saveOutbox()
    }

    /// The iPhone has it as a meeting: now, and only now, the Watch's copy goes.
    fileprivate func confirmed(_ id: UUID) {
        guard let item = outbox.confirmed(id) else { return }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(item.file))
        saveOutbox()
    }

    private func loadOutbox() {
        guard let data = try? Data(contentsOf: Self.outboxURL) else { return }
        do {
            outbox = try JSONDecoder().decode(WatchOutbox.self, from: data)
        } catch {
            NSLog("Ata: could not read the Watch's outbox: \(error.localizedDescription)")
        }
        unsent = outbox.items.count
    }

    private func saveOutbox() {
        unsent = outbox.items.count
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(outbox).write(to: Self.outboxURL, options: .atomic)
        } catch {
            NSLog("Ata: could not save the Watch's outbox: \(error.localizedDescription)")
        }
    }
}

/// WatchConnectivity calls this on a queue of its own.
private final class WatchSessionDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { NSLog("Ata: WatchConnectivity did not activate: \(error.localizedDescription)") }
        Task { @MainActor in WatchModel.shared.becameActive() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in WatchModel.shared.sessionChanged(reachable: reachable) }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = WatchPhoneState(dictionary: applicationContext) else { return }
        Task { @MainActor in WatchModel.shared.received(state) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let state = WatchPhoneState(dictionary: message) else { return }
        Task { @MainActor in WatchModel.shared.received(state) }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let id = WatchAck.id(from: userInfo) else { return }
        Task { @MainActor in WatchModel.shared.confirmed(id) }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = WatchRecordingInfo(metadata: fileTransfer.file.metadata)?.id else { return }
        let text = error?.localizedDescription
        Task { @MainActor in WatchModel.shared.transferFinished(id, error: text) }
    }
}
