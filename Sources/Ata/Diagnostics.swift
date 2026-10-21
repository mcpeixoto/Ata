import AVFoundation
import Foundation

/// `Ata --diagnose`: prints what Ata can and can't access, then records five
/// seconds of both tracks into a temporary folder and reports their levels.
/// Meant to be pasted into a bug report — it prints no personal data.
@MainActor
enum Diagnostics {
    static var requested: Bool { CommandLine.arguments.contains("--diagnose") }

    nonisolated private static func say(_ s: String) { print(s); fflush(stdout) }

    static func run() {
        // Experiment: ask for system audio before anything touches Core Audio.
        if ProcessInfo.processInfo.environment["ATA_DIAG_ASK_FIRST"] == "1", SystemAudioPermission.status == .unknown {
            say("asking for system audio before any Core Audio use…")
            SystemAudioPermission.ask { granted in
                say("answer: \(granted ? "allowed" : "denied")")
                Task { @MainActor in runChecks() }
            }
            return
        }
        runChecks()
    }

    private static func runChecks() {
        let info = Bundle.main.infoDictionary ?? [:]
        say("Ata \(info["CFBundleShortVersionString"] as? String ?? "?") on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        say("microphone permission: \(["notDetermined", "restricted", "denied", "authorized"][mic.rawValue])")
        say("system audio permission: \(SystemAudioPermission.status) (can ask: \(SystemAudioPermission.canAsk))")
        say("output device: \(SystemAudioTap.defaultOutputDevice().map { "#\($0)" } ?? "none")")
        say("whisper-cli: \(Paths.whisperCLI()?.path ?? "not installed")")
        say("local model: \(LocalModel.current.id) \(LocalModel.current.isInstalled ? "installed" : "not downloaded")")
        say("voice recognition: \(Diarization.isSupported ? "supported" : "needs macOS 15")")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-diagnose-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        say("recording 5 s — play something on the Mac and say something…")

        Task { @MainActor in
            let recorder = Recorder()
            do {
                try await recorder.start(in: dir)
            } catch {
                say("recording failed: \(error.localizedDescription)")
                exit(1)
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            _ = await recorder.stop()
            for track in ["mic", "system"] {
                let url = dir.appendingPathComponent("\(track).wav")
                say("\(track): \(String(format: "%.1f", WavWriter.duration(of: url))) s, peak \(peakDB(url))")
            }
            try? FileManager.default.removeItem(at: dir)
            exit(0)
        }
    }

    /// Peak level in dBFS, or "silent".
    private static func peakDB(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return "no audio" }
        var peak: Int32 = 0
        data.dropFirst(44).withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int32(sample))) }
        }
        guard peak > 0 else { return "silent" }
        return String(format: "%.1f dBFS", 20 * log10(Double(peak) / 32768))
    }
}
