import AppKit
import AVFoundation
import CoreGraphics
import ServiceManagement
import UserNotifications

/// Checks and fixes everything the app needs in order to work, from inside the app itself.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var mic = false
    @Published private(set) var screen = false
    @Published private(set) var whisper = false
    @Published private(set) var model = false
    @Published private(set) var notifications = false
    @Published private(set) var launchAtLogin = false

    @Published private(set) var downloadProgress: Double? // nil = no download running
    @Published private(set) var downloadError: String?
    @Published private(set) var installingWhisper = false
    @Published private(set) var whisperStatus: String?
    /// macOS only picks up the screen-recording permission after the app is reopened.
    @Published private(set) var screenNeedsRelaunch = false

    /// True when the OpenAI engine is selected, in which case whisper.cpp and
    /// the local model are not needed to be ready.
    @Published private(set) var usesOpenAI = Engine.current == .openAI
    @Published private(set) var hasOpenAIKey = Keychain.has(Keychain.openAIKey)

    var hasBrew: Bool { Paths.brew() != nil }

    /// Everything needed to record and transcribe with the selected engine.
    var ready: Bool {
        guard mic && screen else { return false }
        return usesOpenAI ? hasOpenAIKey : (whisper && model)
    }

    /// Whether the local engine is installed, regardless of which engine is selected.
    var localEngineReady: Bool { whisper && model }

    var missingSummary: String? {
        var m: [String] = []
        if !mic { m.append(L("microphone")) }
        if !screen { m.append(L("system audio")) }
        if usesOpenAI {
            if !hasOpenAIKey { m.append(L("OpenAI API key")) }
        } else {
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
        screen = CGPreflightScreenCaptureAccess()
        whisper = Paths.whisperCLI() != nil
        model = Paths.hasWhisperModel
        usesOpenAI = Engine.current == .openAI
        hasOpenAIKey = Keychain.has(Keychain.openAIKey)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            self.notifications = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        }
    }

    /// Everything installed and granted, for the snapshot renderer.
    func applySnapshotFixture() {
        mic = true; screen = true; whisper = true; model = true
        notifications = true; launchAtLogin = true
        usesOpenAI = false; hasOpenAIKey = true
        Self.frozen = true
    }

    // MARK: Permissions

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

    func requestScreen() {
        if !CGRequestScreenCaptureAccess() {
            Self.openPrivacy("Privacy_ScreenCapture")
        }
        screenNeedsRelaunch = true
        refresh()
    }

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

    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
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

    // MARK: OpenAI

    enum KeyCheck: Equatable { case idle, checking, ok, failed(String) }
    @Published private(set) var keyCheck: KeyCheck = .idle

    func setEngine(_ engine: Engine) {
        Pref.d.set(engine.rawValue, forKey: Pref.engine)
        keyCheck = .idle
        refresh()
        AppStore.shared.setupChanged()
    }

    /// Stores the key in the keychain (empty string removes it) and verifies it.
    func setOpenAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed.isEmpty ? nil : trimmed, for: Keychain.openAIKey)
        refresh()
        if trimmed.isEmpty {
            keyCheck = .idle
        } else {
            checkOpenAIKey()
        }
    }

    func checkOpenAIKey() {
        guard let client = OpenAIClient() else {
            keyCheck = .failed(L("No OpenAI API key. Add one in Settings → Transcription."))
            return
        }
        keyCheck = .checking
        Task {
            do {
                try await client.validate()
                keyCheck = .ok
                AppStore.shared.setupChanged()
            } catch {
                keyCheck = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: whisper.cpp

    func installWhisper() {
        guard let brew = Paths.brew() else {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        installingWhisper = true
        whisperStatus = L("Installing with Homebrew…")
        let p = Process()
        p.executableURL = brew
        p.arguments = ["install", "whisper-cpp"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let line = String(decoding: h.availableData, as: UTF8.self)
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            guard let line, !line.isEmpty else { return }
            Task { @MainActor in self?.whisperStatus = String(line.prefix(80)) }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.installingWhisper = false
                self.refresh()
                self.whisperStatus = self.whisper ? nil
                    : L("Install failed (code %d). Try in Terminal: brew install whisper-cpp", proc.terminationStatus)
            }
        }
        do { try p.run() } catch {
            installingWhisper = false
            whisperStatus = error.localizedDescription
        }
    }

    // MARK: Models

    func downloadModels() {
        guard downloadProgress == nil else { return }
        downloadError = nil
        downloadProgress = 0
        try? FileManager.default.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)

        // VAD first (1 MB), then the main model (1.6 GB).
        fetch(Paths.vadModelURL, to: Paths.vadModel, skipIf: Paths.hasVADModel, weight: 0) { [weak self] ok in
            guard let self else { return }
            self.fetch(Paths.whisperModelURL, to: Paths.whisperModel, skipIf: Paths.hasWhisperModel, weight: 1) { ok2 in
                self.downloadProgress = nil
                self.refresh()
                if !ok2 && self.downloadError == nil { self.downloadError = L("The download failed. Try again.") }
                _ = ok
            }
        }
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

/// Download with progress, into a temporary file that is only moved into place at the end.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let onProgress: @Sendable (Double) -> Void
    private let completion: @Sendable (Error?) -> Void
    private var moveError: Error?
    private var session: URLSession?

    init(dest: URL, progress: @escaping @Sendable (Double) -> Void, completion: @escaping @Sendable (Error?) -> Void) {
        self.dest = dest
        self.onProgress = progress
        self.completion = completion
    }

    func start(_ url: URL) {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
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
        completion(error ?? moveError)
        session.finishTasksAndInvalidate()
    }
}
