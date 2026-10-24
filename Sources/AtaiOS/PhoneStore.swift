import AVFoundation
import SwiftUI
import UIKit
import WidgetKit

/// The iPhone's single source of truth: recording, the meeting list and the
/// transcription queue. The shared views know it as `AppStore`.
@MainActor
final class PhoneStore: ObservableObject {
    static let shared = PhoneStore()

    enum Phase: Equatable { case idle, starting, recording, interrupted, stopping }

    @Published private(set) var phase: Phase = .idle
    /// Seconds of audio recorded so far.
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var transcribingID: String?
    @Published private(set) var transcribeProgress: Double = 0
    /// Meetings are queued but no engine on this iPhone can transcribe them yet.
    @Published private(set) var waitingForEngine = false
    @Published private(set) var warning: String?
    @Published var lastError: String?
    /// Audio files still being decoded into meetings.
    @Published private(set) var importing = 0
    /// Why the last import failed, until it's dismissed.
    @Published var importError: String?
    @Published var mode: RecordingMode = .inPerson {
        didSet { Pref.d.set(mode.rawValue, forKey: Pref.recordingMode) }
    }
    /// Moments marked during this recording, in ms from its start.
    @Published private(set) var bookmarks: [Int] = []

    var isRecording: Bool { phase == .recording || phase == .interrupted }
    /// Seconds of audio recorded so far, kept current in the background too (unlike `elapsed`).
    var recordedSeconds: Double { recorder.recordedSeconds }

    private let recorder = PhoneRecorder()
    private let activity = LiveRecordingActivity()
    private var ticker: Timer?
    private var job: Task<Void, Never>?
    private var background: ContinuedWork?
    /// iOS ended the background work: wait until Ata is in front before trying again.
    private var queuePaused = false
    private var mergeTasks: [String: Task<Void, Never>] = [:]
    private var searchCache: [String: (stamp: Date?, text: String)] = [:]
    private var bootstrapped = false
    private var drainingInbox = false

    private init() {}

    // MARK: Launch

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        // Read here, on the main thread, before an import off it needs this device's name.
        _ = Device.current
        Pref.registerDefaults()
        mode = Pref.d.string(forKey: Pref.recordingMode).flatMap(RecordingMode.init(rawValue:)) ?? .inPerson
        try? FileManager.default.createDirectory(at: Paths.meetingsDir, withIntermediateDirectories: true)
        // Meetings play through the speaker even with the silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)

        CloudSync.shared.start(isIdle: { PhoneStore.shared.canMoveLibrary },
                               changed: { PhoneStore.shared.libraryChanged() })

        recorder.onPhaseChange = { [weak self] phase in self?.recorderChanged(phase) }
        recorder.onWarning = { [weak self] w in self?.warning = w }

        activity.endLeftovers()
        recoverInterrupted()
        MeetingSharing.cleanUp()
        reload()
        if Pref.d.bool(forKey: Pref.onboarded) == false || AVAudioApplication.shared.recordPermission != .granted {
            PhoneNavigation.shared.showOnboarding()
        }
        drainShareInbox()
        pump()
    }

    /// Ata came to the front: pick up files changed in the meantime, and the queue.
    func becameActive() {
        queuePaused = false
        CloudSync.shared.recheck()
        reload()
        drainShareInbox()
        pump()
    }

    /// Recordings cut short by a crash or a dead battery, and transcriptions iOS
    /// ended, go back into the queue. No audio is ever deleted here: only a
    /// half-decoded import, whose source was never touched.
    private func recoverInterrupted() {
        // The Mac's recovery, run before anything can record or import: WAV
        // headers repaired, a recording cut short queued, an unfinished import
        // cleared (its source is still in its inbox), every folder moved out of staging.
        Library.recoverStaged()
        // Only this iPhone's own work: with the meetings in iCloud, the Mac's
        // "transcribing" may be running right now.
        for m in Library.loadAll() where m.status == .transcribing {
            if let fixed = m.recovered() { Library.save(fixed) }
        }
    }

    func reload() {
        meetings = Library.loadAll()
        updateWidgets()
    }

    /// Nothing is recording, transcribing or importing: the library can move
    /// between this iPhone and iCloud.
    var canMoveLibrary: Bool {
        phase == .idle && transcribingID == nil && importing == 0
    }

    /// The library moved, or the Mac changed it: read it again, voices too.
    func libraryChanged() {
        reload()
        PeopleModel.shared.reload()
        pump()
    }

    // MARK: Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording(app: nil) }
    }

    /// The shared notification code asks for this by the Mac's name; the app
    /// label comes from the mode on iPhone.
    func startRecording(app: String?) {
        Task { try? await start() }
    }

    func startFromIntent() async throws {
        try await start()
    }

    private func start() async throws {
        guard phase == .idle else { return }
        phase = .starting
        lastError = nil
        guard await PhoneRecorder.requestPermission() else {
            phase = .idle
            lastError = L("Allow Ata to use the microphone in Settings to record.")
            PhoneNavigation.shared.showOnboarding()
            throw PhoneRecorderError.micDenied
        }
        do {
            _ = try recorder.start(mode: mode)
            bookmarks = []
            activity.start(mode: mode)
            startTicker()
            reload()
        } catch {
            phase = .idle
            lastError = error.localizedDescription
            throw error
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        phase = .stopping
        let finished = recorder.stop(bookmarks: bookmarks.map { Bookmark(ms: $0) })
        stopTicker()
        activity.end()
        if finished?.moved == false {
            lastError = L("The recording could not be moved into your meetings. It is safe and will be tried again next time Ata opens.")
        }
        bookmarks = []
        phase = .idle
        reload()
        // Wherever the folder is now: one left in staging moves with its meeting.mp3.
        if let m = finished?.meeting, m.status == .pending { saveMergedAudio(of: m) }
        pump()
    }

    func stopFromIntent() async {
        stopRecording()
    }

    func resumeRecording() {
        recorder.resume()
    }

    /// Recordings from the Watch are being imported; see `WatchLink`. Counted with
    /// the other imports, so the library never moves to or from iCloud under one.
    func watchImportStarted() {
        importing += 1
    }

    func watchImportFinished() {
        importing = max(0, importing - 1)
    }

    /// Marks this moment of the recording.
    func addBookmark() {
        guard isRecording else { return }
        bookmarks.append(Int(recorder.recordedSeconds * 1000))
        updateActivity()
    }

    func bookmarkFromIntent() async {
        addBookmark()
    }

    private func recorderChanged(_ phase: RecorderState.Phase) {
        switch phase {
        case .recording: self.phase = .recording
        case .interrupted: self.phase = .interrupted
        case .idle, .stopped: break // stopRecording sets the phase itself
        }
        updateActivity()
    }

    private func updateActivity() {
        activity.update(recorded: recorder.recordedSeconds, paused: phase == .interrupted, bookmarks: bookmarks.count)
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let store = PhoneStore.shared
                // Locked or in the background, nothing is drawing these: save the battery.
                guard UIApplication.shared.applicationState == .active else { return }
                store.elapsed = store.recorder.recordedSeconds
                store.level = store.recorder.level
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        elapsed = 0
        level = 0
    }

    // MARK: Meetings

    func retry(_ m: Meeting) {
        retry(m, with: nil)
    }

    func retry(_ m: Meeting, with override: TranscribeOverride?) {
        var m = m
        // Not while the Mac is transcribing it: its run would overwrite this one.
        guard m.hasAudio, !m.isPlaceholder, m.id != transcribingID, m.canClaim() else { return }
        m.status = .pending
        m.error = nil
        m.override = override
        Library.save(m)
        reload()
        pump()
    }

    func delete(_ m: Meeting) {
        guard m.id != transcribingID else { return }
        Library.trash(m)
        if FileManager.default.fileExists(atPath: m.dir.path) {
            lastError = L("Could not delete this meeting.")
        } else {
            PeopleModel.shared.removeMeeting(m.id)
        }
        reload()
    }

    /// Title, date and transcript in one lowercased string, for the search field.
    /// Transcripts are read once and again only when they change.
    func searchText(for m: Meeting) -> String {
        let url = m.existingTranscriptURL
        let stamp = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        if let cached = searchCache[m.id], cached.stamp == stamp { return cached.text }
        let transcript = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let text = [m.title, m.subtitle, transcript].joined(separator: "\n").lowercased()
        searchCache[m.id] = (stamp, text)
        return text
    }

    // MARK: Import

    /// Audio recorded elsewhere (a voice memo, a file someone sent) becomes a
    /// meeting and goes through the same queue, as on the Mac. The files are only
    /// read: one picked in Files or opened from another app is security-scoped,
    /// and read while Ata has access to it.
    func importAudio(_ urls: [URL]) {
        let files = urls.filter(AudioImport.accepts)
        guard !files.isEmpty else {
            if !urls.isEmpty { importError = L("Ata can only import audio files.") }
            return
        }
        importing += files.count
        Task {
            for url in files {
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        _ = try AudioImport.meeting(from: url)
                    }.value
                    if Self.isHandedOverCopy(url) { try? FileManager.default.removeItem(at: url) }
                } catch {
                    importError = L("Could not import %@: %@", url.lastPathComponent, error.localizedDescription)
                }
                importing -= 1
                reload()
            }
            pump()
        }
    }

    /// Some apps "open in Ata" by handing over a copy in Documents/Inbox, made
    /// for Ata alone; the original stays in that app. Once its meeting exists the
    /// copy has no use, and would only show up in Files.
    private static func isHandedOverCopy(_ url: URL) -> Bool {
        let inbox = URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
        return url.resolvingSymlinksInPath().deletingLastPathComponent().path
            == inbox.resolvingSymlinksInPath().path
    }

    /// Audio shared to Ata from another app waits in the app group's inbox (see
    /// `ShareInbox`). Each file becomes a meeting here; its copy is removed only
    /// once that meeting exists, and one that fails stays for the next time.
    func drainShareInbox() {
        guard !drainingInbox, let folder = ShareInbox.folder else { return }
        let entries = ShareInbox.pending(in: folder)
        guard !entries.isEmpty else { return }
        drainingInbox = true
        importing += entries.count
        Task {
            let report = await Task.detached(priority: .userInitiated) {
                ShareInbox.drain(entries) { entry in
                    _ = try AudioImport.meeting(from: entry.audio, named: entry.item.originalName, at: entry.item.date)
                }
            }.value
            if !report.failed.isEmpty {
                importError = report.failed
                    .map { L("Could not import %@: %@", $0.name, $0.message) }
                    .joined(separator: "\n")
            }
            importing -= entries.count
            drainingInbox = false
            reload()
            pump()
        }
    }

    // MARK: Transcription queue

    /// Whether this iPhone can run the engine a job asks for. The phone transcribes
    /// on the device only, and whisper-cli is a Mac program, so until an on-device
    /// engine is added the queue waits, with the audio kept.
    static func canRun(_ options: TranscribeOptions) -> Bool {
        if options.engine == .openAI { return false }
        if options.engine == .local { return Paths.whisperCLI() != nil }
        return true
    }

    /// Transcribes the next pending meeting (oldest first), one at a time, never
    /// while recording: the microphone and the engine would compete for the phone.
    private func pump() {
        guard transcribingID == nil, !isRecording, phase == .idle, !queuePaused, !CloudSync.shared.copying else { return }
        // With the meetings in iCloud, one the Mac has claimed is skipped, and so is
        // one of the Mac's that this iPhone has no engine for: the Mac will do it.
        let now = Date()
        let waiting = Library.loadAll().filter { $0.awaitsTranscript(now: now) && ($0.isMine || $0.hasAudio) }
        guard var m = waiting.last(where: { $0.isMine || Self.canRun(TranscribeOptions.current(for: $0)) }) else {
            waitingForEngine = false
            return
        }
        let options = TranscribeOptions.current(for: m)
        guard Self.canRun(options) else {
            waitingForEngine = true
            return
        }
        waitingForEngine = false

        transcribingID = m.id
        transcribeProgress = 0
        m.status = .transcribing
        m.override = nil
        m.claim = Claim(device: Device.current, at: Date())
        Library.save(m)
        reload()
        let queued = m

        background = ContinuedWork(title: L("Transcribing"), subtitle: m.title) { [weak self] in
            self?.queuePaused = true
            self?.job?.cancel()
        }
        job = Task {
            var m = queued
            let heartbeat = renewClaim(of: queued.id)
            defer { heartbeat.cancel() }
            // Taken over by the Mac while this iPhone was away: the Mac owns the meeting
            // now, so nothing here is saved and its audio is left alone.
            func stillMine(_ status: Meeting.Status) -> Bool {
                Meeting.mayFinish(status, over: Library.load(queued.id), by: Device.current)
            }
            do {
                let outcome = try await Transcriber.transcribe(m, options: options) { p in
                    Task { @MainActor in
                        let store = PhoneStore.shared
                        guard store.transcribingID == queued.id else { return }
                        store.transcribeProgress = p
                        store.background?.report(p)
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
                if stillMine(.done) {
                    Library.save(m)
                    await handleAudio(of: m)
                    Notifier.shared.transcriptReady(m)
                }
                background?.finish(success: true)
            } catch let error where Self.shouldRequeue(error) {
                // Stopped, not failed: back in the queue with its audio untouched.
                m.status = .pending
                if stillMine(.pending) { Library.save(m) }
                background?.finish(success: false)
            } catch {
                m.status = .failed
                m.error = error.localizedDescription
                m.claim = nil
                if stillMine(.failed) {
                    Library.save(m)
                    Notifier.shared.transcriptFailed(m, error: error.localizedDescription)
                }
                background?.finish(success: false)
            }
            background = nil
            job = nil
            transcribingID = nil
            transcribeProgress = 0
            reload()
            pump()
        }
    }

    /// Renews this iPhone's claim on the meeting being transcribed every few
    /// minutes, so the Mac never takes a long run for an abandoned one. If the Mac
    /// took it over meanwhile (this iPhone was away past the claim), the run stops.
    private func renewClaim(of id: String) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled, transcribingID == id, var fresh = Library.load(id) else { return }
                // meeting.json is still coming down from iCloud: renewed next time round.
                if fresh.isPlaceholder { continue }
                guard fresh.status == .transcribing, fresh.isClaimed() else {
                    NSLog("Ata: another device took over \(id); this iPhone stops transcribing it")
                    job?.cancel()
                    return
                }
                fresh.claim = Claim(device: Device.current, at: Date())
                Library.save(fresh)
            }
        }
    }

    /// Cancelled, ended by iOS, or no engine to run: try again later. Anything
    /// else is a real failure, shown with "Try again" so one bad file doesn't
    /// block the queue.
    static func shouldRequeue(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        switch error as? TranscriberError {
        case .cancelled?, .whisperMissing?, .modelMissing?: return true
        default: return false
        }
    }

    /// After a successful transcript: keep the audio (compressed, by default) or
    /// delete it if you asked for that. The same rules as on the Mac, and like
    /// there only for this iPhone's own recordings.
    private func handleAudio(of m: Meeting) async {
        guard m.isMine else { return }
        await saveMergedAudio(of: m)?.value
        guard Pref.d.bool(forKey: Pref.keepAudio) else {
            try? FileManager.default.removeItem(at: m.micURL)
            try? FileManager.default.removeItem(at: m.systemURL)
            try? FileManager.default.removeItem(at: m.mergedAudioURL)
            return
        }
        guard Pref.d.bool(forKey: Pref.compressAudio) else { return }
        for wav in [m.micURL, m.systemURL] where Paths.fileSize(wav) > 44 {
            _ = await AudioFiles.compressToM4A(wav)
        }
    }

    /// Writes meeting.mp3 in the background, once per meeting; see the Mac's AppStore.
    @discardableResult
    func saveMergedAudio(of m: Meeting) -> Task<Void, Never>? {
        if let running = mergeTasks[m.id] { return running }
        // Another device's meeting is left to that device, which may be writing its own.
        guard Pref.d.bool(forKey: Pref.keepAudio), Pref.d.bool(forKey: Pref.saveMP3),
              m.isMine, m.status != .recording, m.hasAudio, !m.hasMergedAudio else { return nil }
        let task = Task {
            let job = m
            do {
                try await Task.detached(priority: .utility) { try MergedAudio.write(job) }.value
            } catch {
                NSLog("Ata: could not write meeting.mp3 for \(job.id): \(error.localizedDescription)")
            }
            self.mergeTasks[job.id] = nil
        }
        mergeTasks[m.id] = task
        return task
    }

    // MARK: Screenshots

    /// For the screenshot run only (`-AtaSnapshots`, see PhoneSnapshots.swift), in
    /// place of `bootstrap()`: the fixture meetings and a made-up recording, with
    /// no microphone, no queue and nothing written.
    func applySnapshotFixture(recording: Bool, elapsed: Double, level: Float, bookmarks: [Int],
                              transcribingID: String?, progress: Double) {
        guard Snapshots.rendering else { return }
        bootstrapped = true
        meetings = Library.loadAll()
        phase = recording ? .recording : .idle
        self.elapsed = elapsed
        self.level = level
        self.bookmarks = bookmarks
        self.transcribingID = transcribingID
        transcribeProgress = progress
    }

    // MARK: Widgets

    private func updateWidgets() {
        let last = meetings.first { $0.status != .recording }
        let snapshot = WidgetSnapshot(lastTitle: last?.title, lastStartedAt: last?.startedAt,
                                      recordingSince: isRecording ? Date().addingTimeInterval(-recorder.recordedSeconds) : nil)
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }
}
