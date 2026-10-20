import AppKit
import AVFoundation
import SwiftUI

/// Estado central da app: gravação, deteção de meetings, fila de transcrição e histórico.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    enum Phase: Equatable { case idle, starting, recording, stopping }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var now = Date()
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var warning: String?
    @Published private(set) var detectedApp: String?
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var transcribingID: String?
    @Published private(set) var transcribeProgress: Double = 0
    @Published var lastError: String?

    let setup = SetupModel()
    private let recorder = Recorder()
    private let detector = MeetingDetector()
    private var current: Meeting?
    private var ticker: Timer?
    private var autoStarted = false
    private var bootstrapped = false
    private var pendingAutoStop = false
    private var lastSystemSoundAt = Date()

    private init() {}

    // MARK: - Arranque

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        Pref.registerDefaults()
        try? FileManager.default.createDirectory(at: Paths.meetingsDir, withIntermediateDirectories: true)
        setup.refresh()

        recorder.onWarning = { [weak self] w in self?.warning = w }
        detector.onStart = { [weak self] app in self?.meetingStarted(app) }
        detector.onEnd = { [weak self] in self?.meetingEnded() }
        if Pref.d.bool(forKey: Pref.autoDetect) { detector.start() }

        recoverInterrupted()
        pump()
    }

    /// Gravações interrompidas (crash, falta de bateria, app fechada à força) voltam para a fila.
    private func recoverInterrupted() {
        for var m in Library.loadAll() {
            switch m.status {
            case .recording:
                let d1 = WavWriter.repairHeader(m.micURL)
                let d2 = WavWriter.repairHeader(m.systemURL)
                m.duration = max(d1, d2)
                m.endedAt = m.endedAt ?? m.startedAt.addingTimeInterval(max(d1, d2))
                m.status = m.hasAudio ? .pending : .failed
                if !m.hasAudio { m.error = "Gravação vazia" }
                Library.save(m)
            case .transcribing:
                m.status = .pending
                Library.save(m)
            default:
                break
            }
        }
        reload()
    }

    func reload() {
        meetings = Library.loadAll()
    }

    func setAutoDetect(_ on: Bool) {
        Pref.d.set(on, forKey: Pref.autoDetect)
        if on { detector.start() } else { detector.stop(); detectedApp = nil }
    }

    // MARK: - Deteção

    private func meetingStarted(_ app: String) {
        detectedApp = app
        pendingAutoStop = false
        guard phase == .idle else { return }
        if Pref.d.bool(forKey: Pref.autoStart) && setup.ready {
            autoStarted = true
            startRecording(app: app)
        } else {
            Notifier.shared.meetingDetected(app: app)
        }
    }

    private func meetingEnded() {
        detectedApp = nil
        Notifier.shared.clear("detected")
        // Só para quando também já não há som da meeting (ex.: alguém com o micro em mute não conta como fim).
        if phase == .recording && Pref.d.bool(forKey: Pref.autoStop) && (autoStarted || current?.app != nil) {
            pendingAutoStop = true
        }
    }

    // MARK: - Gravação

    var elapsed: TimeInterval { startedAt.map { now.timeIntervalSince($0) } ?? 0 }

    var elapsedText: String {
        let s = Int(elapsed)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    var currentApp: String? { current?.app }

    func toggleRecording() {
        switch phase {
        case .idle: startRecording(app: detectedApp)
        case .recording: stopRecording()
        default: break
        }
    }

    func startRecording(app: String?) {
        guard phase == .idle else { return }
        setup.refresh()
        guard setup.mic || AVAuthorization.micUndetermined else {
            lastError = "Dá acesso ao microfone para gravar."
            WindowManager.shared.showOnboarding()
            return
        }
        phase = .starting
        lastError = nil
        Notifier.shared.clear("detected")

        Task {
            do {
                let m = try Meeting.new(app: app)
                Library.save(m)
                current = m
                try await recorder.start(in: m.dir)
                startedAt = Date()
                lastSystemSoundAt = Date()
                phase = .recording
                startTicker()
                reload()
                if !autoStarted { Notifier.shared.clear("recording") } else { Notifier.shared.recordingStarted(app: app) }
            } catch {
                if let m = current { try? FileManager.default.removeItem(at: m.dir) }
                current = nil
                phase = .idle
                autoStarted = false
                lastError = error.localizedDescription
                setup.refresh()
                if error is RecorderError { WindowManager.shared.showOnboarding() }
                reload()
            }
        }
    }

    func stopRecording() {
        guard phase == .recording, let snapshot = current else { return }
        phase = .stopping
        pendingAutoStop = false
        Task {
            var m = snapshot
            let duration = await recorder.stop()
            stopTicker()
            m.endedAt = Date()
            m.duration = duration
            m.status = m.hasAudio ? .pending : .failed
            if !m.hasAudio { m.error = "Gravação vazia" }
            Library.save(m)
            current = nil
            startedAt = nil
            autoStarted = false
            phase = .idle
            Notifier.shared.clear("recording")
            reload()
            pump()
        }
    }

    /// Para e apaga a gravação atual.
    func discardRecording() {
        guard phase == .recording, let m = current else { return }
        phase = .stopping
        Task {
            _ = await recorder.stop()
            stopTicker()
            try? FileManager.default.removeItem(at: m.dir)
            current = nil
            startedAt = nil
            autoStarted = false
            phase = .idle
            Notifier.shared.clear("recording")
            reload()
        }
    }

    /// Chamado ao sair da app: fecha os ficheiros para a gravação ser transcrita no próximo arranque.
    func prepareForQuit() async {
        if phase == .recording, var m = current {
            let duration = await recorder.stop()
            m.endedAt = Date()
            m.duration = duration
            m.status = .pending
            Library.save(m)
        }
        Transcriber.currentProcess?.terminate()
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                self.micLevel = self.recorder.micLevel
                self.systemLevel = self.recorder.systemLevel
                if self.systemLevel > 0.2 { self.lastSystemSoundAt = self.now }
                if self.pendingAutoStop, self.phase == .recording, self.detectedApp == nil,
                   self.now.timeIntervalSince(self.lastSystemSoundAt) > 10 {
                    self.pendingAutoStop = false
                    self.stopRecording()
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        micLevel = 0
        systemLevel = 0
    }

    // MARK: - Fila de transcrição

    func retry(_ m: Meeting) {
        var m = m
        guard m.hasAudio else { return }
        m.status = .pending
        m.error = nil
        Library.save(m)
        reload()
        pump()
    }

    func delete(_ m: Meeting) {
        guard m.id != current?.id, m.id != transcribingID else { return }
        Library.trash(m)
        reload()
    }

    /// Transcreve a próxima meeting pendente (a mais antiga primeiro), uma de cada vez.
    private func pump() {
        guard transcribingID == nil else { return }
        guard var m = Library.loadAll().last(where: { $0.status == .pending }) else { return }
        guard setup.whisper && setup.model else {
            setup.refresh()
            return // fica na fila até o setup estar completo
        }

        transcribingID = m.id
        transcribeProgress = 0
        m.status = .transcribing
        Library.save(m)
        reload()
        let job = m

        let name = Pref.d.string(forKey: Pref.myName) ?? "Eu"
        let lang = Pref.d.string(forKey: Pref.language) ?? "auto"
        Task {
            var m = job
            do {
                _ = try await Transcriber.transcribe(m, myName: name, language: lang) { p in
                    Task { @MainActor in AppStore.shared.transcribeProgress = p }
                }
                m.status = .done
                m.error = nil
                if !Pref.d.bool(forKey: Pref.keepAudio) {
                    try? FileManager.default.removeItem(at: m.micURL)
                    try? FileManager.default.removeItem(at: m.systemURL)
                }
                Library.save(m)
                Notifier.shared.transcriptReady(m)
            } catch {
                m.status = .failed
                m.error = error.localizedDescription
                Library.save(m)
                Notifier.shared.transcriptFailed(m, error: error.localizedDescription)
            }
            transcribingID = nil
            transcribeProgress = 0
            reload()
            pump()
        }
    }

    /// Quando o setup fica completo, processar o que estiver na fila.
    func setupChanged() {
        setup.refresh()
        pump()
    }
}

enum AVAuthorization {
    static var micUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }
}
