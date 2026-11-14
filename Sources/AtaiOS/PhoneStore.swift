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
    /// What the transcription is doing now, so a model download is not "Transcribing…".
    @Published private(set) var transcribeStage: TranscribeStage?
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
    /// Free meetings made on this iPhone this month; see `FreeQuota`.
    @Published private(set) var freeUsed = 0

    /// No free meeting left this month, and no Ata Pro.
    var needsPro: Bool { !ProStore.shared.isPro && freeUsed >= FreeQuota.limit }

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
    /// Meetings whose speech model could not be downloaded. Retried when Ata is in front.
    private var waitingForSpeechModel: Set<String> = []
    private var lastHealth = Date.distantPast
    private var lastStallRestart = Date.distantPast
    private var lastActivityRefresh = Date.distantPast
    private var terminateObserver: NSObjectProtocol?

    private init() {}

    // MARK: Launch

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        // Read here, on the main thread, before an import off it needs this device's name.
        _ = Device.current
        Pref.registerDefaults()
        mode = Pref.d.string(forKey: Pref.recordingMode).flatMap(RecordingMode.init(rawValue:)) ?? .inPerson
        try? CloudLibrary.createFolder(Paths.meetingsDir)
        // Meetings play through the speaker even with the silent switch on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)

        CloudSync.shared.start(isIdle: { PhoneStore.shared.canMoveLibrary },
                               changed: { PhoneStore.shared.libraryChanged() })

        recorder.onPhaseChange = { [weak self] phase in self?.recorderChanged(phase) }
        recorder.onWarning = { [weak self] w in self?.warning = w }

        activity.endLeftovers()
        // A force-quit does not always deliver this. The Live Activity's stale
        // date covers that; this covers a termination iOS does announce.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PhoneStore.shared.stopRecording() }
        }
        recoverInterrupted()
        MeetingSharing.cleanUp()
        reload()
        if Pref.d.bool(forKey: Pref.onboarded) == false {
            PhoneNavigation.shared.showOnboarding()
        }
        drainShareInbox()
        pump()
        Metrics.sendIfDue()
    }

    /// Ata came to the front: pick up files changed in the meantime, and the queue.
    func becameActive() {
        queuePaused = false
        // An interruption that never handed the microphone back stays paused
        // until Ata is in front. Resuming in the background would fight the
        // app that still holds it.
        if phase == .interrupted { resumeRecording() }
        for id in waitingForSpeechModel { RunEnd.retryNow(id) }
        waitingForSpeechModel.removeAll()
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
        updateQuota()
        updateWidgets()
    }

    /// Counted again before every start too: the month may have turned since.
    func updateQuota() {
        guard !Snapshots.rendering else { return }
        freeUsed = FreeQuota.used(meetings: meetings, ledger: QuotaLedger.ids(), deviceID: Device.id)
    }

    /// Made on this iPhone: counted against this month's free meetings.
    private func counted(_ meetingID: String) {
        QuotaLedger.record(meetingID)
        updateQuota()
    }

    /// After an import, which is never refused: past the free meetings, Pro is offered.
    private func offerProIfOverLimit() {
        if !ProStore.shared.isPro && freeUsed > FreeQuota.limit { PhoneNavigation.shared.showPaywall() }
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
        try await start(fromIntent: true)
    }

    /// The free limit and a denied microphone are worth opening Ata for. Anything
    /// else (no room, already recording) stays where the intent left it.
    nonisolated static func shouldOpenForBlockedStart(_ error: Error) -> Bool {
        if error is FreeQuotaError { return true }
        if let recorderError = error as? PhoneRecorderError, case .micDenied = recorderError { return true }
        return false
    }

    var isApplicationActive: Bool { UIApplication.shared.applicationState == .active }

    /// Shows the paywall or the microphone message only when Ata is in front, or
    /// this request is bringing it there. Otherwise the sheet would wait until
    /// the next time the app opened, with nothing to explain it.
    func presentBlockedStart(_ error: Error, appIsActive: Bool, becomingForeground: Bool) {
        guard BlockedStart.presentation(appIsActive: appIsActive, becomingForeground: becomingForeground) == .showNow else { return }
        if error is FreeQuotaError {
            PhoneNavigation.shared.showPaywall()
            return
        }
        if let recorderError = error as? PhoneRecorderError, case .micDenied = recorderError {
            lastError = L("Allow Ata to use the microphone in Settings to record.")
            PhoneNavigation.shared.showOnboarding(at: .permissions)
        }
    }

    private func start(fromIntent: Bool = false) async throws {
        guard phase == .idle else { return }
        // Siri and the Control come through here too. A recording
        // already running is never stopped by this; it only gates a new one.
        updateQuota()
        // At the limit, record nothing. From an intent the sheet is armed only
        // after Ata is in front; see `presentBlockedStart`.
        do {
            try RecordingStart.begin(needsPro: needsPro, record: {})
        } catch {
            if !fromIntent { PhoneNavigation.shared.showPaywall() }
            throw error
        }
        phase = .starting
        lastError = nil
        guard await PhoneRecorder.requestPermission() else {
            phase = .idle
            if !fromIntent {
                lastError = L("Allow Ata to use the microphone in Settings to record.")
                PhoneNavigation.shared.showOnboarding(at: .permissions)
            }
            throw PhoneRecorderError.micDenied
        }
        // The microphone and a transcription would compete. Same pause as when
        // iOS ends the background task: the job is cancelled and the meeting
        // goes back to pending, audio untouched.
        applyQueue(.recordingWillStart)
        do {
            guard RecordingHealth.hasRoom(available: Self.freeBytes()) else {
                throw PhoneRecorderError.notEnoughSpace
            }
            _ = try recorder.start(mode: mode)
            bookmarks = []
            lastHealth = .distantPast
            lastStallRestart = .distantPast
            lastActivityRefresh = Date()
            activity.start(mode: mode)
            startTicker()
            reload()
        } catch {
            applyQueue(.recordingStopped)
            phase = .idle
            lastError = Self.message(forStartFailure: error)
            pump()
            throw error
        }
    }

    /// `volumeAvailableCapacityForImportantUsageKey` — declared in the privacy
    /// manifest (disk space, E174.1) because a recording has to have somewhere to go.
    private static func freeBytes() -> Int64? {
        let values = try? Paths.meetingsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A sentence Ata wrote passes through. Anything from the audio system
    /// becomes one line; the raw error stays in the log.
    static func message(forStartFailure error: Error) -> String {
        if error is PhoneRecorderError || error is FreeQuotaError {
            return RecordingStartMessage.text(knownDescription: error.localizedDescription)
        }
        NSLog("Ata: could not start recording: \(error)")
        return RecordingStartMessage.text(knownDescription: nil)
    }

    func stopRecording() {
        guard isRecording else { return }
        phase = .stopping
        warning = nil
        Notifier.shared.clear("paused")
        let finished = recorder.stop(bookmarks: bookmarks.map { Bookmark(ms: $0) })
        stopTicker()
        activity.end()
        if let finished, FreeQuota.countsWhenStopped(duration: finished.meeting.duration,
                                                     hasAudio: finished.meeting.status != .failed) {
            counted(finished.meeting.id)
        }
        if finished?.moved == false {
            lastError = L("The recording could not be moved into your meetings. It is safe and will be tried again next time Ata opens.")
        }
        bookmarks = []
        phase = .idle
        // The queue was paused for the recording. It can take the next meeting.
        applyQueue(.recordingStopped)
        reload()
        // Wherever the folder is now: one left in staging moves with its meeting.mp3.
        if let m = finished?.meeting, m.status == .pending {
            Metrics.recorded(seconds: m.duration ?? 0)
            saveMergedAudio(of: m)
        }
        pump()
    }

    func stopFromIntent() async {
        stopRecording()
    }

    func resumeRecording() {
        recorder.resume()
    }

    /// Marks this moment of the recording.
    func addBookmark() {
        guard isRecording else { return }
        bookmarks.append(Int(recorder.recordedSeconds * 1000))
        recorder.noteBookmarks(bookmarks)
        updateActivity()
    }

    func bookmarkFromIntent() async {
        addBookmark()
    }

    private func recorderChanged(_ phase: RecorderState.Phase) {
        switch phase {
        case .recording:
            self.phase = .recording
            Notifier.shared.clear("paused")
        case .interrupted:
            self.phase = .interrupted
            // shouldResume: false leaves it here, and iOS will not hand the
            // microphone back. Say so only when nobody is looking at the screen.
            if UIApplication.shared.applicationState != .active {
                let message = L("Recording paused. Open Ata to resume.")
                Notifier.shared.recordingAlert(message, id: "paused")
            }
        case .idle, .stopped: break // stopRecording sets the phase itself
        }
        updateActivity()
        // Pause and resume have to reach the widget. The live timer is a date,
        // and reload() is not called when the phase changes on its own.
        updateWidgets()
    }

    private func updateActivity(force: Bool = false) {
        activity.update(recorded: recorder.recordedSeconds, paused: phase == .interrupted,
                        bookmarks: bookmarks.count, force: force)
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let store = PhoneStore.shared
                store.maintainRecording()
                // Locked or in the background, nothing is drawing these: save the battery.
                guard UIApplication.shared.applicationState == .active else { return }
                store.elapsed = store.recorder.recordedSeconds
                store.level = store.recorder.level
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Disk full and a stalled microphone, once a second, including in the
    /// background. The level meter above this stays on the tenth-of-a-second tick.
    private func maintainRecording() {
        guard isRecording else { return }
        let now = Date()
        if RecordingHealth.shouldRefreshActivity(secondsSinceRefresh: now.timeIntervalSince(lastActivityRefresh)) {
            lastActivityRefresh = now
            updateActivity(force: true)
        }
        guard now.timeIntervalSince(lastHealth) >= 1 else { return }
        lastHealth = now
        if recorder.writeFailed {
            let message = L("This iPhone's storage is full, so the recording stopped growing.")
            Notifier.shared.recordingAlert(message, id: "storage")
            stopRecording()
            warning = message
            return
        }
        guard RecordingHealth.shouldRestartCapture(
            capturing: recorder.isCapturing,
            secondsSinceBuffer: recorder.secondsSinceBuffer,
            secondsSinceRestart: now.timeIntervalSince(lastStallRestart)) else { return }
        lastStallRestart = now
        recorder.restartStalledCapture()
        if warning == nil {
            warning = L("The microphone went quiet. Ata is starting it again.")
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
        if !Library.trash(m) {
            lastError = L("Could not delete this meeting.")
        } else {
            PeopleModel.shared.removeMeeting(m.id)
        }
        reload()
    }

    /// Title, date, category and transcript in one lowercased string, for the
    /// search field. Transcripts are read once and again only when they change;
    /// the category is added after the cache, since it changes without them.
    func searchText(for m: Meeting) -> String {
        let category = m.categoryValue.map { "\n" + $0.name.lowercased() } ?? ""
        let url = m.existingTranscriptURL
        let stamp = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        if let cached = searchCache[m.id], cached.stamp == stamp { return cached.text + category }
        let transcript = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let text = [m.title, m.subtitle, transcript].joined(separator: "\n").lowercased()
        searchCache[m.id] = (stamp, text)
        return text + category
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
                    let m = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try AudioImport.meeting(from: url)
                    }.value
                    counted(m.id)
                    if Self.isHandedOverCopy(url) { try? FileManager.default.removeItem(at: url) }
                } catch {
                    importError = L("Could not import %@: %@", url.lastPathComponent, error.localizedDescription)
                }
                importing -= 1
                reload()
            }
            offerProIfOverLimit()
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
                    let m = try AudioImport.meeting(from: entry.audio, named: entry.item.originalName, at: entry.item.date)
                    QuotaLedger.record(m.id)
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
            offerProIfOverLimit()
            pump()
        }
    }

    // MARK: Transcription queue

    /// The phone's engine needs nothing installed first.
    var queueReason: String? { nil }

    /// Whether this iPhone can run the engine a job asks for. Apple speech runs
    /// on the device. whisper-cli is a Mac program, so a meeting that asks for
    /// it waits here, with the audio kept, for a Mac that has it.
    static func canRun(_ options: TranscribeOptions) -> Bool {
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
        let waiting = Library.loadAll().filter { RunEnd.awaits($0, now: now) && ($0.isMine || $0.hasAudio) }
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
        transcribeStage = nil
        m.status = .transcribing
        m.error = nil
        m.override = nil
        m.claim = Claim(device: Device.current, at: Date())
        Library.save(m)
        reload()
        let queued = m

        background = ContinuedWork(title: L("Transcribing"), subtitle: m.title) { [weak self] in
            self?.applyQueue(.backgroundExpired)
        }
        job = Task {
            let heartbeat = renewClaim(of: queued.id)
            defer { heartbeat.cancel() }
            // Saved onto meeting.json as it is now, and only while the claim is still this
            // run's (see `RunEnd`): if the Mac took it over while this iPhone was away, the
            // Mac owns the meeting, so nothing here is saved and its audio is left alone.
            do {
                let outcome = try await Transcriber.transcribe(queued, options: options, progress: { p in
                    Task { @MainActor in
                        let store = PhoneStore.shared
                        guard store.transcribingID == queued.id else { return }
                        store.transcribeProgress = p
                        store.background?.report(p)
                    }
                }, stage: { s in
                    Task { @MainActor in
                        let store = PhoneStore.shared
                        guard store.transcribingID == queued.id else { return }
                        store.transcribeStage = s
                    }
                })
                if let m = await RunEnd.save(queued.id, as: .done, apply: RunEnd.done(outcome)) {
                    await handleAudio(of: m)
                    Notifier.shared.transcriptReady(m)
                }
                background?.finish(success: true)
            } catch let error where Self.shouldRequeue(error) {
                // Stopped, not failed: back in the queue with its audio untouched. Audio
                // still in iCloud gives up the claim, so the Mac that has it can do it.
                // A missing speech model waits for a connection instead of failing the
                // meeting, and is not tried again until Ata is in front — an offline
                // phone would otherwise spin the queue.
                if SpeechModelQueue.waitsForConnection(error) {
                    if await RunEnd.save(queued.id, as: .pending, apply: { m in
                        m.claim = nil
                        m.error = L("Waiting for a connection to download the speech model")
                    }) != nil {
                        waitingForSpeechModel.insert(queued.id)
                        RunEnd.retryLater(queued.id)
                    }
                } else if RunEnd.releasesClaim(error) {
                    RunEnd.retryLater(queued.id)
                    _ = await RunEnd.save(queued.id, as: .pending) { $0.claim = nil }
                } else {
                    _ = await RunEnd.save(queued.id, as: .pending)
                }
                background?.finish(success: false)
            } catch {
                let message = error.localizedDescription
                if let m = await RunEnd.save(queued.id, as: .failed, apply: { m in
                    m.error = message
                    m.claim = nil
                }) {
                    Notifier.shared.transcriptFailed(m, error: message)
                }
                background?.finish(success: false)
            }
            background = nil
            job = nil
            transcribingID = nil
            transcribeProgress = 0
            transcribeStage = nil
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

    /// Cancelled, ended by iOS, no engine to run, or the audio still in iCloud
    /// (`RunEnd.releasesClaim`): try again later. Anything
    /// else is a real failure, shown with "Try again" so one bad file doesn't
    /// block the queue.
    static func shouldRequeue(_ error: Error) -> Bool {
        if error is CancellationError || RunEnd.releasesClaim(error) { return true }
        if SpeechModelQueue.waitsForConnection(error) { return true }
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
            for url in m.audioFilesToDiscard { try? Coordinated.remove(url) }
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
                              transcribingID: String?, progress: Double, freeUsed: Int) {
        guard Snapshots.rendering else { return }
        self.freeUsed = freeUsed
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
        let face = WidgetRecordingFace.face(isRecording: isRecording, isPaused: phase == .interrupted,
                                            recordedSeconds: recorder.recordedSeconds, now: Date())
        let snapshot = WidgetSnapshot(lastTitle: last?.title, lastStartedAt: last?.startedAt,
                                      recordingSince: face.recordingSince, pausedSeconds: face.pausedSeconds)
        if snapshot.save() { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// Pause or resume the transcription queue. Cancelling the running job is
    /// what saves the meeting back as pending: the job's catch treats
    /// cancellation as "try again", and no audio is deleted.
    private func applyQueue(_ event: RecordingQueue.Event) {
        let decision = RecordingQueue.decide(event, jobRunning: job != nil)
        queuePaused = decision.queuePaused
        if decision.cancelJob { job?.cancel() }
    }
}

extension FreeQuotaError: LocalizedError {
    var errorDescription: String? {
        L("You have used this month's %d free meetings on iPhone. Ata Pro records without a limit.", FreeQuota.limit)
    }
}
