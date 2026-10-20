import AppKit
import AVFoundation
import CoreGraphics
import ServiceManagement
import UserNotifications

/// Verifica e resolve tudo o que a app precisa para funcionar, dentro da própria app.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var mic = false
    @Published private(set) var screen = false
    @Published private(set) var whisper = false
    @Published private(set) var model = false
    @Published private(set) var notifications = false
    @Published private(set) var launchAtLogin = false

    @Published private(set) var downloadProgress: Double? // nil = sem download em curso
    @Published private(set) var downloadError: String?
    @Published private(set) var installingWhisper = false
    @Published private(set) var whisperStatus: String?
    /// O macOS só reconhece a permissão de gravação de ecrã depois de reabrir a app.
    @Published private(set) var screenNeedsRelaunch = false

    var hasBrew: Bool { Paths.brew() != nil }
    var ready: Bool { mic && screen && whisper && model }
    var missingSummary: String? {
        var m: [String] = []
        if !mic { m.append("microfone") }
        if !screen { m.append("áudio do sistema") }
        if !whisper { m.append("motor de transcrição") }
        if !model { m.append("modelo") }
        return m.isEmpty ? nil : "Falta: " + m.joined(separator: ", ")
    }

    private var downloader: Downloader?

    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        screen = CGPreflightScreenCaptureAccess()
        whisper = Paths.whisperCLI() != nil
        model = Paths.hasWhisperModel
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Task {
            let s = await UNUserNotificationCenter.current().notificationSettings()
            self.notifications = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
        }
    }

    // MARK: Permissões

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

    // MARK: Arranque automático

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Ata: launch at login: \(error)")
        }
        refresh()
    }

    // MARK: whisper.cpp

    func installWhisper() {
        guard let brew = Paths.brew() else {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        installingWhisper = true
        whisperStatus = "A instalar com o Homebrew…"
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
                self.whisperStatus = self.whisper ? nil : "A instalação falhou (código \(proc.terminationStatus)). Tenta no Terminal: brew install whisper-cpp"
            }
        }
        do { try p.run() } catch {
            installingWhisper = false
            whisperStatus = error.localizedDescription
        }
    }

    // MARK: Modelos

    func downloadModels() {
        guard downloadProgress == nil else { return }
        downloadError = nil
        downloadProgress = 0
        try? FileManager.default.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)

        // Primeiro o VAD (1 MB), depois o modelo principal (1.6 GB).
        fetch(Paths.vadModelURL, to: Paths.vadModel, skipIf: Paths.hasVADModel, weight: 0) { [weak self] ok in
            guard let self else { return }
            self.fetch(Paths.whisperModelURL, to: Paths.whisperModel, skipIf: Paths.hasWhisperModel, weight: 1) { ok2 in
                self.downloadProgress = nil
                self.refresh()
                if !ok2 && self.downloadError == nil { self.downloadError = "O download falhou. Tenta de novo." }
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

/// Download com progresso, para um ficheiro temporário que só é movido para o destino no fim.
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
                                userInfo: [NSLocalizedDescriptionKey: "O servidor respondeu \(http.statusCode)."])
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
