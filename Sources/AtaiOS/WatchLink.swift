import AVFoundation
import Combine
import UIKit
import WatchConnectivity

/// Imports run one at a time, off the main thread: decoding an hour of audio
/// takes a few seconds.
private let watchImportQueue = DispatchQueue(label: "ai.interactive.ata.watch-import", qos: .utility)

/// The iPhone's side of Ata on the Apple Watch.
///
/// - The Watch's buttons arrive as messages and go through the same calls as
///   the App Intents; each one is answered with what the iPhone is doing now.
/// - Every change of phase or bookmarks is pushed to the Watch as the
///   application context, and as a message while it is reachable.
/// - Recordings made on the Watch arrive as file transfers and become meetings
///   through `WatchImport`; the Watch is told it may delete its copy only once
///   the meeting exists.
///
/// Starting from the Watch while Ata is in the background: WatchConnectivity
/// wakes Ata in the background to answer, but iOS only lets an app turn the
/// microphone on from the background through an audio-recording App Intent,
/// which a message isn't. Ata tries anyway; when iOS says no, the Watch is told
/// to ask you to open Ata on the iPhone, or to record on the Watch instead.
@MainActor
final class WatchLink {
    static let shared = WatchLink()

    private let delegate = PhoneSessionDelegate()
    private var observers: Set<AnyCancellable> = []
    private var activated = false

    private init() {}

    func activate() {
        guard !activated, WCSession.isSupported() else { return }
        activated = true
        let session = WCSession.default
        session.delegate = delegate
        session.activate()

        let store = PhoneStore.shared
        // On the next turn of the main loop: @Published sends before the value is stored.
        store.$phase.removeDuplicates().map { _ in () }
            .merge(with: store.$bookmarks.removeDuplicates().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.push() }
            .store(in: &observers)

        // Recordings received last time and not imported yet.
        importWaiting()
    }

    // MARK: State

    func currentState(problem: WatchPhoneState.Problem? = nil, detail: String? = nil) -> WatchPhoneState {
        let store = PhoneStore.shared
        let phase: WatchPhoneState.Phase
        switch store.phase {
        case .idle: phase = .idle
        case .starting: phase = .starting
        case .recording: phase = .recording
        case .interrupted: phase = .interrupted
        case .stopping: phase = .stopping
        }
        return WatchPhoneState(phase: phase, recorded: store.recordedSeconds, at: Date(),
                               bookmarks: store.bookmarks.count, problem: problem, detail: detail)
    }

    func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let state = currentState().dictionary
        do {
            try session.updateApplicationContext(state)
        } catch {
            NSLog("Ata: could not update the Watch: \(error.localizedDescription)")
        }
        if session.isReachable {
            session.sendMessage(state, replyHandler: nil, errorHandler: nil)
        }
    }

    // MARK: Commands

    func handle(_ command: WatchCommand, reply: @escaping ([String: Any]) -> Void) {
        Task {
            let store = PhoneStore.shared
            switch command {
            case .state:
                break
            case .start:
                guard store.phase == .idle else { break }
                // Asking for the microphone needs Ata on screen.
                guard AVAudioApplication.shared.recordPermission == .granted else {
                    reply(currentState(problem: .microphone).dictionary)
                    return
                }
                do {
                    try await store.startFromIntent()
                } catch {
                    let inFront = UIApplication.shared.applicationState == .active
                    // Not your doing, and the Watch explains it: no error waiting on the iPhone.
                    if !inFront { store.lastError = nil }
                    reply(currentState(problem: inFront ? .failed : .openPhone,
                                       detail: error.localizedDescription).dictionary)
                    return
                }
            case .stop:
                await store.stopFromIntent()
            case .bookmark:
                await store.bookmarkFromIntent()
            }
            reply(currentState().dictionary)
        }
    }

    // MARK: Recordings from the Watch

    func importWaiting() {
        watchImportQueue.async {
            let done = WatchImport.importWaiting()
            guard !done.isEmpty else { return }
            Task { @MainActor in WatchLink.shared.imported(done) }
        }
    }

    private func imported(_ ids: [UUID]) {
        let session = WCSession.default
        // If this one is lost, the Watch sends the recording again within the
        // hour, and it is only confirmed again.
        if session.activationState == .activated {
            for id in ids { session.transferUserInfo(WatchAck.message(for: id)) }
        }
        PhoneStore.shared.libraryChanged()
    }
}

/// WatchConnectivity calls this on a queue of its own.
private final class PhoneSessionDelegate: NSObject, WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { NSLog("Ata: WatchConnectivity did not activate: \(error.localizedDescription)") }
        Task { @MainActor in WatchLink.shared.push() }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// You switched to another Watch: talk to that one.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in WatchLink.shared.push() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in WatchLink.shared.push() }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = WatchCommand(message: message) else {
            replyHandler([:])
            return
        }
        Task { @MainActor in WatchLink.shared.handle(command, reply: replyHandler) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = WatchCommand(message: message) else { return }
        Task { @MainActor in WatchLink.shared.handle(command, reply: { _ in }) }
    }

    /// The file is deleted when this returns: move it into the inbox first.
    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let info = WatchRecordingInfo(metadata: file.metadata) else {
            NSLog("Ata: a file from the Watch came without its details: \(file.fileURL.lastPathComponent)")
            return
        }
        do {
            try WatchImport.keep(file.fileURL, info: info)
        } catch {
            // Not confirmed, so the Watch keeps its copy and sends it again.
            NSLog("Ata: could not keep the Watch recording \(info.id): \(error.localizedDescription)")
            return
        }
        Task { @MainActor in WatchLink.shared.importWaiting() }
    }
}
