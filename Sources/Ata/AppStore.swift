import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Central app state: recording, meeting detection, the transcription queue and the history.
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
    /// Moments marked in the recording in progress.
    @Published private(set) var bookmarkCount = 0
    /// Audio files still being decoded into meetings.
    @Published private(set) var importing = 0
    @Published var lastError: String?

    let setup = SetupModel()
    private let recorder = Recorder()
    private let detector = MeetingDetector()
    private var current: Meeting?
    private var ticker: Timer?
    private var maintenance: Timer?
    private var autoStarted = false
    private var bootstrapped = false
    private var pendingAutoStop = false
    private var lastSystemSoundAt = Date()
    private var mergeTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Launch

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        Pref.registerDefaults()
        try? FileManager.default.createDirectory(at: Paths.meetingsDir, withIntermediateDirectories: true)
        setup.refresh()
        CloudSync.shared.start(isIdle: { AppStore.shared.canMoveLibrary },
                               changed: { AppStore.shared.libraryChanged() })

        recorder.onWarning = { [weak self] w in self?.warning = w }
        detector.onStart = { [weak self] app in self?.meetingStarted(app) }
        detector.onEnd = { [weak self] in self?.meetingEnded() }
        if Pref.d.bool(forKey: Pref.autoDetect) { detector.start() }

        recoverInterrupted()
        pruneOldAudio()
        pump()
        MeetingSharing.cleanUp()
        backfillMergedAudio()
        Updater.shared.checkInBackground()
        // Ata often runs for weeks as a login item: retention and update checks
        // can't only happen at launch.
        maintenance = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppStore.shared.pruneOldAudio()
                Updater.shared.checkInBackground()
            }
        }
    }

    /// Interrupted recordings (crash, power loss, force quit) go back into the
    /// queue: first whatever was left in staging, then this device's meetings
    /// in the meetings folder. Another device's are left as they are.
    private func recoverInterrupted() {
        Library.recoverStaged()
        for m in Library.loadAll() {
            if let fixed = m.recovered() { Library.save(fixed) }
        }
        reload()
    }

    func reload() {
        meetings = Library.loadAll()
    }

    /// Nothing is recording, transcribing or importing: the library can move
    /// between this Mac's folder and iCloud. An MP3 being mixed doesn't hold it up:
    /// it lands next to the original tracks, and the copy picks it up next time.
    var canMoveLibrary: Bool {
        phase == .idle && transcribingID == nil && importing == 0
    }

    /// The library moved, or another device changed it: read it again, voices
    /// too, and pick up anything that is now waiting.
    func libraryChanged() {
        reload()
        PeopleModel.shared.reload()
        pump()
    }

    /// How much audio is being kept, for the Settings screen.
    var storageText: String {
        let bytes = meetings.reduce(Int64(0)) { $0 + $1.audioBytes }
        guard bytes > 0 else { return L("nothing") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Deletes audio from meetings older than the retention window, keeping the
    /// transcripts. Runs at launch; 0 means keep audio forever. Only this
    /// device's meetings: another device's audio follows that device's setting.
    func pruneOldAudio() {
        let days = Pref.d.integer(forKey: Pref.audioRetentionDays)
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for m in Library.loadAll() where m.isMine && m.status == .done && m.startedAt < cutoff {
            for url in [m.micAudioURL, m.systemAudioURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            try? FileManager.default.removeItem(at: m.mergedAudioURL)
        }
    }

    func setAutoDetect(_ on: Bool) {
        Pref.d.set(on, forKey: Pref.autoDetect)
        if on { detector.start() } else { detector.stop(); detectedApp = nil }
    }

    // MARK: - Detection

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
        // Only stop once the meeting audio has gone quiet too (a muted participant is not the end).
        if phase == .recording && Pref.d.bool(forKey: Pref.autoStop) && (autoStarted || current?.app != nil) {
            pendingAutoStop = true
        }
    }

    // MARK: - Recording

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
        // An auto-stop armed for an earlier meeting must never end this one.
        pendingAutoStop = false
        setup.refresh()
        guard setup.mic || AVAuthorization.micUndetermined else {
            lastError = L("Grant microphone access to record.")
            WindowManager.shared.showOnboarding()
            return
        }
        phase = .starting
        lastError = nil
        Notifier.shared.clear("detected")

        Task {
            do {
                // Written in staging and moved into the meetings folder when it stops,
                // so a synced folder never holds a half-written WAV.
                let m = try Meeting.new(app: app, staged: true)
                Library.save(m)
                bookmarkCount = 0
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
                // Only a refused permission is something the welcome window can fix.
                if let e = error as? RecorderError, e.isPermission { WindowManager.shared.showOnboarding() }
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
            if !m.hasAudio { m.error = L("Empty recording") }
            Library.save(m)
            m = Library.publish(m)
            current = nil
            startedAt = nil
            autoStarted = false
            bookmarkCount = 0
            phase = .idle
            Notifier.shared.clear("recording")
            reload()
            // Ready to listen to in seconds, long before the transcript is.
            if m.hasAudio { saveMergedAudio(of: m) }
            pump()
        }
    }

    /// Stops and deletes the current recording.
    func discardRecording() {
        guard phase == .recording, let m = current else { return }
        phase = .stopping
        pendingAutoStop = false
        Task {
            _ = await recorder.stop()
            stopTicker()
            try? FileManager.default.removeItem(at: m.dir)
            current = nil
            startedAt = nil
            autoStarted = false
            bookmarkCount = 0
            phase = .idle
            Notifier.shared.clear("recording")
            reload()
        }
    }

    /// Called when the app quits: closes the files so the recording is transcribed on next launch.
    func prepareForQuit() async {
        if phase == .recording, var m = current {
            let duration = await recorder.stop()
            m.endedAt = Date()
            m.duration = duration
            m.status = .pending
            Library.save(m)
            Library.publish(m)
        }
        LocalEngine.currentProcess?.terminate()
    }

    /// Marks this moment of the recording in progress. The time comes from the
    /// audio written so far, so the mark lands where it was heard.
    func addBookmark(note: String? = nil) {
        guard phase == .recording, var m = current else { return }
        let seconds = max(recorder.mic?.duration ?? 0, recorder.sys?.duration ?? 0)
        let ms = Int(((seconds > 0 ? seconds : elapsed) * 1000).rounded())
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        m.bookmarks = (m.bookmarks ?? []) + [Bookmark(ms: ms, note: text?.isEmpty == false ? text : nil)]
        current = m
        bookmarkCount = m.bookmarks?.count ?? 0
        // Saved now, so a crash mid-meeting keeps the marks too.
        Library.save(m)
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

    // MARK: - Import

    /// Audio recorded elsewhere (a voice memo, a recorder, a file someone sent)
    /// becomes a meeting and goes through the same queue. The files themselves
    /// are only read, never moved or changed.
    func importAudio(_ urls: [URL]) {
        let files = urls.filter(AudioImport.accepts)
        guard !files.isEmpty else {
            if !urls.isEmpty { lastError = L("Ata can only import audio files.") }
            return
        }
        importing += files.count
        Task {
            for url in files {
                do {
                    try await Task.detached(priority: .userInitiated) { _ = try AudioImport.meeting(from: url) }.value
                } catch {
                    lastError = L("Could not import %@: %@", url.lastPathComponent, error.localizedDescription)
                }
                importing -= 1
                reload()
            }
            pump()
        }
    }

    // MARK: - Transcription queue

    func retry(_ m: Meeting) {
        retry(m, with: nil)
    }

    /// Queues a meeting again, optionally with a different engine and model
    /// than the current settings. The transcript it replaces is kept in versions/.
    func retry(_ m: Meeting, with override: TranscribeOverride?) {
        var m = m
        // Not while another device is transcribing it: its run would overwrite this one.
        guard m.hasAudio, !m.isPlaceholder, m.id != transcribingID, m.id != current?.id, m.canClaim() else { return }
        m.status = .pending
        m.error = nil
        m.override = override
        Library.save(m)
        reload()
        pump()
    }

    func delete(_ m: Meeting) {
        guard m.id != current?.id, m.id != transcribingID else { return }
        Library.trash(m)
        PeopleModel.shared.removeMeeting(m.id)
        reload()
    }

    /// Transcribes the next pending meeting (oldest first), one at a time.
    /// With the folder shared, a meeting another device has claimed is
    /// skipped, and so is another device's whose audio hasn't arrived yet.
    private func pump() {
        // Not while the library is being copied into iCloud: it moves once nothing uses it.
        guard transcribingID == nil, !CloudSync.shared.copying else { return }
        let now = Date()
        guard var m = Library.loadAll().last(where: { $0.awaitsTranscript(now: now) && ($0.isMine || $0.hasAudio) })
        else { return }

        let options = TranscribeOptions.current(for: m)
        switch options.engine {
        case .local:
            guard setup.whisper else {
                setup.refresh()
                return // stays queued until the local engine is installed
            }
            guard LocalModel.find(options.localModel)?.isInstalled == true else {
                if m.override != nil {
                    // A one-off request for a model that isn't here would block
                    // the whole queue; fail just this meeting instead.
                    m.override = nil
                    m.status = .failed
                    m.error = L("That model is not downloaded. Download it in Settings → Transcription.")
                    Library.save(m)
                    reload()
                    pump()
                }
                return // the default model is still downloading: stays queued
            }
        case .apple:
            break // nothing to install first: the engine downloads its language model itself
        case .openAI:
            guard Keychain.has(Keychain.openAIKey) else {
                lastError = L("No OpenAI API key. Add one in Settings → Transcription.")
                return // stays queued until a key is available
            }
        }

        transcribingID = m.id
        transcribeProgress = 0
        m.status = .transcribing
        m.override = nil
        m.claim = Claim(device: Device.current, at: Date())
        Library.save(m)
        reload()
        let job = m

        Task {
            var m = job
            let heartbeat = renewClaim(of: job.id)
            do {
                let outcome = try await Transcriber.transcribe(m, options: options) { p in
                    Task { @MainActor in
                        if AppStore.shared.transcribingID == job.id { AppStore.shared.transcribeProgress = p }
                    }
                }
                var history = m.transcriptions ?? []
                if let archived = outcome.archivedPrevious, !history.isEmpty {
                    history[history.count - 1].archivedAs = archived
                }
                history.append(outcome.record)
                m.transcriptions = history
                m.status = .done
                m.error = nil
                m.claim = nil
                Library.save(m)
                await self.handleAudio(of: m)
                Notifier.shared.transcriptReady(m)
            } catch TranscriberError.cancelled {
                // Stopped because Ata is quitting: back in the queue for the next launch,
                // still claimed, so another device only takes it if this one stays away.
                m.status = .pending
                Library.save(m)
            } catch {
                m.status = .failed
                m.error = error.localizedDescription
                m.claim = nil
                Library.save(m)
                Notifier.shared.transcriptFailed(m, error: error.localizedDescription)
            }
            heartbeat.cancel()
            transcribingID = nil
            transcribeProgress = 0
            reload()
            pump()
        }
    }

    /// Renews this device's claim on the meeting being transcribed every few
    /// minutes, so a long run is never taken for an abandoned one.
    private func renewClaim(of id: String) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled, transcribingID == id,
                      var fresh = Library.load(id), fresh.status == .transcribing else { return }
                fresh.claim = Claim(device: Device.current, at: Date())
                Library.save(fresh)
            }
        }
    }

    /// After a successful transcript: keep the audio (the default) and compress
    /// it, or delete it if the user asked for that. Only for this device's
    /// meetings; another device's audio follows that device's settings.
    private func handleAudio(of m: Meeting) async {
        guard m.isMine else { return }
        // The tracks are about to be compressed or deleted: let the MP3 finish
        // reading them first, or write it now if it was never started.
        await saveMergedAudio(of: m)?.value
        guard Pref.d.bool(forKey: Pref.keepAudio) else {
            try? FileManager.default.removeItem(at: m.micURL)
            try? FileManager.default.removeItem(at: m.systemURL)
            try? FileManager.default.removeItem(at: m.mergedAudioURL)
            return
        }
        guard Pref.d.bool(forKey: Pref.compressAudio) else { return }
        for wav in [m.micURL, m.systemURL] where Paths.fileSize(wav) > 44 {
            await AudioFiles.compressToM4A(wav)
        }
    }

    /// Writes meeting.mp3 in the background, when the settings ask for one and
    /// it isn't there yet. Returns the running job so callers can wait for it;
    /// asking twice for the same meeting gives back the same job.
    @discardableResult
    func saveMergedAudio(of m: Meeting) -> Task<Void, Never>? {
        if let running = mergeTasks[m.id] { return running }
        // A meeting still recording would give an MP3 cut off wherever it was when asked.
        // Another device's meeting is left to that device, which may be writing its own.
        guard Pref.d.bool(forKey: Pref.keepAudio), Pref.d.bool(forKey: Pref.saveMP3),
              m.isMine, m.status != .recording, m.hasAudio, !m.hasMergedAudio else { return nil }
        let task = Task {
            let job = m
            do {
                try await Task.detached(priority: .utility) { try MergedAudio.write(job) }.value
            } catch {
                // The tracks are untouched, so nothing is lost: the next attempt starts over.
                NSLog("Ata: could not write meeting.mp3 for \(job.id): \(error.localizedDescription)")
            }
            self.mergeTasks[job.id] = nil
        }
        mergeTasks[m.id] = task
        return task
    }

    /// Gives every meeting recorded before Ata 2.4 its meeting.mp3, newest
    /// first and one at a time, so an upgrade never decodes the whole history at once.
    func backfillMergedAudio() {
        guard Pref.d.bool(forKey: Pref.keepAudio), Pref.d.bool(forKey: Pref.saveMP3) else { return }
        let pending = MergedAudio.missing(in: Library.loadAll())
        guard !pending.isEmpty else { return }
        Task {
            for m in pending {
                await saveMergedAudio(of: m)?.value
            }
        }
    }

    /// Once setup is complete, work through whatever is queued.
    func setupChanged() {
        setup.refresh()
        if setup.hasOpenAIKey, lastError == L("No OpenAI API key. Add one in Settings → Transcription.") {
            lastError = nil
        }
        pump()
    }
}

extension AppStore {
    /// Puts the store into a fixed state for the snapshot renderer. Nothing is
    /// recorded and no engine runs; only what the views read is set.
    func applySnapshotFixture(recordingApp: String?, elapsed: TimeInterval, mic: Float, system: Float,
                              transcribingID: String?, progress: Double) {
        ticker?.invalidate()
        let now = Date()
        self.now = now
        if let recordingApp {
            current = Meeting(id: "snapshot", startedAt: now.addingTimeInterval(-elapsed), endedAt: nil,
                              duration: nil, app: recordingApp, status: .recording, error: nil)
            startedAt = now.addingTimeInterval(-elapsed)
            phase = .recording
        } else {
            current = nil
            startedAt = nil
            phase = .idle
        }
        micLevel = mic
        systemLevel = system
        self.transcribingID = transcribingID
        transcribeProgress = progress
        detectedApp = nil
        warning = nil
        lastError = nil
        meetings = Library.loadAll()
    }
}

enum AVAuthorization {
    static var micUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }
}
