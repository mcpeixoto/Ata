import Foundation
#if os(macOS)
import AppKit
import AVFoundation
import CoreGraphics
import ServiceManagement
import UserNotifications

/// Checks and fixes everything the app needs in order to work, from inside the app itself.
///
/// The Mac's checklist: system audio, the Whisper model, launch at login.
/// The iPhone asks for what it needs in its own onboarding; only `Downloader`
/// below is shared.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var mic = false
    /// System audio permission ("System Audio Recording Only").
    @Published private(set) var systemAudio = false
    @Published private(set) var systemAudioStatus = SystemAudioPermission.Status.unknown
    @Published private(set) var whisper = false
    @Published private(set) var model = false
    @Published private(set) var notifications = false
    /// Permission to read the calendar. Optional, like notifications: Ata has
    /// to stay fully usable without it, so it is deliberately not part of `ready`.
    @Published private(set) var calendar = false
    @Published private(set) var calendarStatus = CalendarAccess.Status.notDetermined
    /// Ata asked for the calendar and macOS showed nothing — see
    /// `CalendarAccess.NextStep`. Settings says so, because otherwise the only
    /// evidence is a dialog that never appeared.
    @Published private(set) var calendarAskWasSilent = false
    @Published private(set) var launchAtLogin = false

    /// Refused, or granted only enough to add events. macOS will not ask again
    /// either way, so the only route back is the settings pane.
    var calendarDenied: Bool { calendarStatus == .denied || calendarStatus == .writeOnly }

    @Published private(set) var downloadProgress: Double? // nil = no download running
    @Published private(set) var downloadError: String?
    /// Denied, or not asked yet when Ata could ask. When Ata can't read the
    /// state at all, macOS asks on the first recording, so that isn't missing.
    var systemAudioMissing: Bool {
        systemAudioStatus == .denied || (systemAudioStatus == .unknown && SystemAudioPermission.canAsk)
    }

    /// Everything needed to record and transcribe with the selected engine.
    var ready: Bool {
        guard mic && !systemAudioMissing else { return false }
        return Engine.current.needsWhisper ? (whisper && model) : true
    }

    var missingSummary: String? {
        var m: [String] = []
        if !mic { m.append(L("microphone")) }
        if systemAudioMissing { m.append(L("system audio")) }
        if Engine.current.needsWhisper {
            if !whisper { m.append(L("transcription engine")) }
            if !model { m.append(L("model")) }
        }
        return m.isEmpty ? nil : L("Missing: %@", m.joined(separator: ", "))
    }

    private var downloader: Downloader?

    /// Set by the snapshot renderer so the screenshots show a finished setup
    /// instead of whatever this machine happens to have granted.
    static var frozen = false

    func refresh() {
        guard !Self.frozen else { return }
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        systemAudioStatus = SystemAudioPermission.status
        systemAudio = systemAudioStatus == .authorized
        if !Snapshots.rendering && !Diagnostics.requested { restartIfAudioWasJustGranted() }
        let wasReady = ready
        whisper = Paths.whisperCLI() != nil
        model = Paths.hasWhisperModel
        startDownloadIfNeeded()
        // Meetings may be queued for exactly this, whichever window is open or not.
        if !wasReady, ready { DispatchQueue.main.async { AppStore.shared.setupChanged() } }
        calendarStatus = CalendarAccess.status
        calendar = calendarStatus == .authorized
        if calendar { calendarAskWasSilent = false }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            self.notifications = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        }
    }

    /// Everything installed and granted, for the snapshot renderer.
    func applySnapshotFixture() {
        mic = true; systemAudio = true; systemAudioStatus = .authorized; whisper = true; model = true
        notifications = true; launchAtLogin = true
        calendar = true; calendarStatus = .authorized
        Self.frozen = true
    }

    // MARK: Permissions

    /// Shows the system prompt the first time; after a refusal macOS will not
    /// ask again, so this opens the settings pane instead. The microphone's
    /// shape, not system audio's: EventKit honours a grant in the process that
    /// is already running, so there is nothing to restart.
    func requestCalendar() {
        Task {
            let before = CalendarAccess.status
            if before == .notDetermined { _ = await CalendarAccess.request() }
            let after = CalendarAccess.status
            calendarAskWasSilent = CalendarAccess.wasSilent(before: before, after: after)
            if CalendarAccess.nextStep(before: before, after: after) == .openSettings {
                Self.openPrivacy("Privacy_Calendars")
            }
            refresh()
            AppStore.shared.calendarChanged()
        }
    }

    /// The one button of the first step: microphone, notifications, then system
    /// audio last, because granting that one restarts Ata.
    func allowRecording() {
        Task {
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            if mic == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if mic != .authorized {
                Self.openPrivacy("Privacy_Microphone")
                refresh()
                return
            }
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            refresh()
            if systemAudioMissing { requestSystemAudio() }
        }
    }

    func requestMic() {
        Task {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else if status != .authorized {
                Self.openPrivacy("Privacy_Microphone")
            }
            refresh()
        }
    }

    /// Shows the system prompt the first time; after a refusal, macOS won't ask
    /// again, so this opens the settings pane instead. A grant is noticed by
    /// `refresh`, which restarts Ata; see `restartIfAudioWasJustGranted`.
    func requestSystemAudio() {
        if systemAudioStatus != .denied,
           SystemAudioPermission.ask({ [weak self] _ in Task { @MainActor in self?.refresh() } }) {
            return
        }
        Self.openPrivacy("Privacy_AudioCapture")
    }

    /// The permission state when this process started. Core Audio settles a
    /// process's right to capture system audio when the process first uses it,
    /// so a grant given while Ata is running only takes effect after a restart
    /// (measured: the tap delivered nothing until then).
    private let systemAudioAtLaunch = SystemAudioPermission.status

    /// Granted, and the restart it takes is about to happen.
    private var restartPending: Bool {
        systemAudioAtLaunch != .authorized && systemAudioStatus == .authorized
    }

    /// Restarts Ata once, by itself, right after system audio was granted —
    /// never during a recording. Called from `refresh`.
    private func restartIfAudioWasJustGranted() {
        guard systemAudioAtLaunch != .authorized, systemAudioStatus == .authorized,
              !Self.restarting, AppStore.shared.phase == .idle else { return }
        Self.restarting = true
        NSLog("Ata: system audio was just allowed; restarting so capture can use it")
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\" --args \(LaunchWindow.quietArgument)"]
        try? p.run()
        NSApp.terminate(nil)
    }

    private static var restarting = false

    func requestNotifications() {
        Task {
            let c = UNUserNotificationCenter.current()
            let s = await c.notificationSettings()
            if s.authorizationStatus == .notDetermined {
                _ = try? await c.requestAuthorization(options: [.alert, .sound])
            } else if s.authorizationStatus == .denied {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                    NSWorkspace.shared.open(url)
                }
            }
            refresh()
        }
    }

    static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Apple Intelligence has no in-app prompt. This opens the System Settings
    /// pane where it is turned on. Siri's pane first: that is where Apple
    /// Intelligence is on macOS 26, and macOS claims success for a pane it does
    /// not have, so a wrong one first would never reach the right one.
    static func openAppleIntelligence() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            "x-apple.systempreferences:com.apple.Apple-Intelligence-Settings.extension",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Ata: launch at login: \(error)")
        }
        refresh()
    }

    // MARK: Models

    /// Starts on its own, but not while system audio is unanswered: that answer
    /// restarts Ata, and this is too large to throw away a moment in.
    private func startDownloadIfNeeded() {
        guard NSApp != nil, !Snapshots.rendering, !Diagnostics.requested,
              downloadProgress == nil, downloadError == nil, !model || !Paths.hasVADModel,
              !restartPending, !(systemAudioStatus == .unknown && SystemAudioPermission.canAsk) else { return }
        downloadModels()
    }

    func downloadModels() {
        guard downloadProgress == nil else { return }
        downloadError = nil
        try? FileManager.default.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)

        let model = LocalModel.current
        if !model.isInstalled, !DiskCheck.hasRoom(available: DiskCheck.available(at: Paths.modelsDir), needed: model.bytes) {
            let free = ByteCountFormatter.string(fromByteCount: DiskCheck.available(at: Paths.modelsDir) ?? 0, countStyle: .file)
            downloadError = L("Whisper Large needs %@ of free disk space, and %@ is free. Free some up and try again.",
                              ByteCountFormatter.string(fromByteCount: model.bytes + DiskCheck.margin, countStyle: .file), free)
            return
        }
        downloadProgress = 0
        // VAD first (1 MB), then the main model (1.1 GB). Each is tried on its
        // own: a failed VAD must not stop the model, and comes back next time.
        fetch(Paths.vadModelURL, to: Paths.vadModel, skipIf: Paths.hasVADModel, weight: 0) { [weak self] vadOK in
            guard let self else { return }
            self.fetch(model.url, to: model.path, skipIf: model.isInstalled, weight: 1) { modelOK in
                self.downloadProgress = nil
                if vadOK && modelOK { self.downloadError = nil }
                if !modelOK && self.downloadError == nil { self.downloadError = L("The download failed. Try again.") }
                self.refresh()
                // Meetings may be waiting for exactly this model.
                AppStore.shared.setupChanged()
            }
        }
    }

    /// So a quit doesn't start a 1 GB download over.
    func keepDownloadForLater() {
        downloader?.keepForLater()
    }

    private func fetch(_ url: URL, to dest: URL, skipIf: Bool, weight: Double,
                       done: @escaping @MainActor (Bool) -> Void) {
        if skipIf { done(true); return }
        let d = Downloader(dest: dest) { [weak self] p in
            Task { @MainActor in if weight > 0 { self?.downloadProgress = p } }
        } completion: { [weak self] error in
            Task { @MainActor in
                if let error { self?.downloadError = error.localizedDescription }
                done(error == nil)
            }
        }
        downloader = d
        d.start(url)
    }
}
#endif

/// Download with progress, into a temporary file that is only moved into place
/// at the end. What arrived before a failure or a quit is kept beside the target,
/// so the next try carries on from there.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let onProgress: @Sendable (Double) -> Void
    private let completion: @Sendable (Error?) -> Void
    private var moveError: Error?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    init(dest: URL, progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Error?) -> Void) {
        self.dest = dest
        self.onProgress = progress
        self.completion = completion
    }

    private var resumeFile: URL { dest.appendingPathExtension("resume") }

    /// 206 is what a resumed download ends with: the server sent the rest.
    static func isComplete(status: Int) -> Bool { status == 200 || status == 206 }

    func start(_ url: URL) {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        let saved = try? Data(contentsOf: resumeFile)
        // Used once: if it no longer works, the next try starts clean.
        try? FileManager.default.removeItem(at: resumeFile)
        let t = saved.map { s.downloadTask(withResumeData: $0) } ?? s.downloadTask(with: url)
        task = t
        t.resume()
    }

    /// Waits a moment at most: this runs while Ata is quitting.
    func keepForLater() {
        guard let task else { return }
        let done = DispatchSemaphore(value: 0)
        let file = resumeFile
        task.cancel { data in
            if let data { try? data.write(to: file, options: .atomic) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !Self.isComplete(status: http.statusCode) {
            moveError = NSError(domain: "Ata", code: http.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: L("The server replied %d.", http.statusCode)])
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile, options: .atomic)
        }
        completion(error ?? moveError)
        session.finishTasksAndInvalidate()
    }
}
