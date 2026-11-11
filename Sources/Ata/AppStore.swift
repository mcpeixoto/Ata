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
    /// The clock, the meters and the progress live in `LiveValues`, which
    /// changes many times a second: published from here, every view that
    /// reads the store — and stats files for each meeting — redrew with it.
    let live = LiveValues.shared
    var now: Date { live.now }
    var micLevel: Float { live.micLevel }
    var systemLevel: Float { live.systemLevel }
    var transcribeProgress: Double { live.transcribeProgress }
    @Published private(set) var warning: String?
    private var writingOwedSummaries = false
    private var triedOwedSummaries = Set<String>()
    @Published private(set) var detectedApp: String?
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var transcribingID: String?
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
    /// The transcription running now, so it can stop if another device takes it over.
    private var transcribeJob: Task<Void, Never>?
    /// Meetings the launch repair scan has not reached yet. Their system track
    /// may be rewritten under them, so they are neither transcribed nor pruned
    /// until it has.
    private var repairingIDs: Set<String> = []
    /// Meetings whose audio is being compressed or removed after their
    /// transcript: not retried or deleted until that is over.
    private var audioJobs: Set<String> = []
    private var reloading = false
    private var reloadAgain = false
    private var pumping = false
    private var pumpAgain = false

    private init() {}

    // MARK: - Launch

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        Pref.registerDefaults()
        try? CloudLibrary.createFolder(Paths.meetingsDir)
        setup.refresh()
        CloudSync.shared.start(isIdle: { AppStore.shared.canMoveLibrary },
                               changed: { AppStore.shared.libraryChanged() })

        recorder.onWarning = { [weak self] w in self?.warning = w }
        detector.onStart = { [weak self] app in self?.meetingStarted(app) }
        detector.onEnd = { [weak self] in self?.meetingEnded() }
        if Pref.d.bool(forKey: Pref.autoDetect) { detector.start() }

        recoverInterrupted()
        removeLeftoverLanguagePieces()
        repairCorruptedSystemTracks()
        pruneOldAudio()
        pump()
        MeetingSharing.cleanUp()
        backfillMergedAudio()
        Updater.shared.checkInBackground()
        Metrics.sendIfDue()
        // Ata often runs for weeks as a login item: retention and update checks
        // can't only happen at launch.
        maintenance = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated {
                AppStore.shared.pruneOldAudio()
                Updater.shared.checkInBackground()
                Metrics.sendIfDue()
            }
        }
    }

    /// `languages-*` is the scratch directory of a mixed-language pass, removed
    /// when the pass finishes. A crash leaves it in the meeting folder. A
    /// meeting another device is transcribing right now is left alone — its
    /// pieces may be the ones it is in the middle of.
    private func removeLeftoverLanguagePieces() {
        for meeting in Library.loadAll() where meeting.status != .transcribing {
            LanguagePieces.remove(in: meeting.dir)
        }
    }

    /// System tracks Ata 2.11 wrote at double speed are put back, and the
    /// meeting is transcribed again. The original file stays in the folder.
    /// A healthy track an earlier repair slowed by mistake gets its original
    /// back, and is transcribed again too.
    ///
    /// Judging a track decodes all of it, so the scan runs off the main actor,
    /// at utility priority, one meeting at a time: at launch it used to hold
    /// the menu bar for as long as the whole history took to decode. Only the
    /// meetings the broken writer could have made are looked at, and a meeting
    /// waits out of the queue until the scan has been past it.
    private func repairCorruptedSystemTracks() {
        let since = SystemAudioRepair.fixedWriterSince()
        let candidates = Library.loadAll().filter { SystemAudioRepair.mayHoldBrokenTrack($0, fixedSince: since) }
        guard !candidates.isEmpty else { return }
        let jobs = candidates.map { (id: $0.id, dir: $0.dir) }
        repairingIDs.formUnion(jobs.map(\.id))
        Task.detached(priority: .utility) {
            for job in jobs {
                let outcome = SystemAudioRepair.examine(job.dir)
                await AppStore.shared.repairChecked(job.id, outcome: outcome)
            }
        }
    }

    private func repairChecked(_ id: String, outcome: SystemAudioRepair.Outcome) {
        repairingIDs.remove(id)
        defer { pump() }
        guard let meeting = Library.load(id), let fixed = SystemAudioRepair.applying(outcome, to: meeting) else {
            return
        }
        Library.save(fixed)
        reload()
        switch outcome {
        case .repaired: NSLog("Ata: \(id) flagged — its system audio was corrupted; it will be transcribed again")
        case .restored: NSLog("Ata: \(id) has its original system track back; it will be transcribed again")
        case .unchanged: break
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

    /// Reads every meeting folder off the main actor and publishes the list.
    /// Called from everywhere, often several times in a row: one read runs at
    /// a time, and calls that land meanwhile are folded into one more after it.
    /// It used to read the whole library on the main thread every time, which
    /// froze the menu bar more the longer the history grew.
    func reload() {
        guard !reloading else { reloadAgain = true; return }
        reloading = true
        Task {
            let all = await Task.detached(priority: .userInitiated) { Library.loadAll() }.value
            meetings = all
            reloading = false
            // It reads `meetings`, which the callers that asked for it before
            // this reload became asynchronous expected to be current.
            writeOwedSummaries()
            if reloadAgain {
                reloadAgain = false
                reload()
            }
        }
    }

    /// Nothing is recording, transcribing, importing or compressing a finished
    /// meeting's tracks: the library can move
    /// between this Mac's folder and iCloud. An MP3 being mixed doesn't hold it up:
    /// it lands next to the original tracks, and the copy picks it up next time.
    var canMoveLibrary: Bool {
        phase == .idle && transcribingID == nil && importing == 0 && audioJobs.isEmpty
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
        let repairing = repairingIDs
        // Every meeting folder is read and every audio file stat'ed: not on the main thread.
        Task.detached(priority: .utility) {
            for m in Library.loadAll() where m.isMine && m.status == .done && m.startedAt < cutoff
                && !repairing.contains(m.id) {
                for url in m.keptAudioFiles {
                    try? Coordinated.remove(url)
                }
            }
        }
    }

    /// The calendar settings or the grant changed: the scheduled prompts have
    /// to match what the user just asked for.
    func calendarChanged() {
        CalendarWatcher.shared.start()
    }

    func setAutoDetect(_ on: Bool) {
        Pref.d.set(on, forKey: Pref.autoDetect)
        if on { detector.start() } else { detector.stop(); detectedApp = nil }
    }

    // MARK: - Detection

    private func meetingStarted(_ app: String) {
        detectedApp = app
        pendingAutoStop = false
        // Already recording because the calendar said so, and only now is Zoom
        // on the microphone: the meeting keeps the event's title and gains the
        // app, so Insights' "Where" chart still has something to group it under.
        if phase == .recording, var m = current, m.app == nil {
            m.app = app
            current = m
            Library.save(m)
        }
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

    /// Starts recording a meeting Ata knows the calendar event for: the event
    /// names the folder, the window and the transcript, and its attendees are
    /// the names "Who's this?" will offer for the voices heard in it.
    ///
    /// Re-read from the calendar first where it can be. A prompt scheduled an
    /// hour ago may be quoting a title that has since changed — and it never
    /// refuses, because the user tapped Record.
    func startRecording(event: MeetingEvent?) {
        let fresh = event.flatMap { CalendarStore.shared.refresh($0) } ?? event
        startRecording(app: detectedApp, event: fresh)
    }

    /// `started` hears whether the recording is running, once that is known:
    /// false when it was refused or failed to start.
    func startRecording(app: String?, event: MeetingEvent? = nil,
                        started: (@MainActor (Bool) -> Void)? = nil) {
        guard phase == .idle else { started?(false); return }
        // An auto-stop armed for an earlier meeting must never end this one.
        pendingAutoStop = false
        setup.refresh()
        guard setup.mic || AVAuthorization.micUndetermined else {
            lastError = L("Grant microphone access to record.")
            WindowManager.shared.showOnboarding()
            started?(false)
            return
        }
        // Asked here, during a call, the grant would only count after a restart:
        // the other side of this meeting would never be captured.
        guard !setup.systemAudioMissing else {
            lastError = L("Allow system audio first, or Ata can't hear the other side.")
            WindowManager.shared.showOnboarding()
            started?(false)
            return
        }
        if let free = DiskCheck.available(at: Paths.meetingsDir), free < DiskCheck.lowForRecording {
            lastError = L("The disk is almost full (%@ free). Ata may not be able to save a long recording.",
                          ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        }
        phase = .starting
        Notifier.shared.clear("detected")

        Task {
            do {
                // Written in staging and moved into the meetings folder when it stops,
                // so a synced folder never holds a half-written WAV.
                var m = try Meeting.new(app: app, event: event, staged: true)
                // Read before capture starts: a device plugged in halfway
                // through does not change who was in the room at the start.
                m.soloMicrophone = InputDevices.isSolo
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
                started?(true)
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
                started?(false)
            }
        }
    }

    func stopRecording() {
        guard phase == .recording, let snapshot = current else { return }
        phase = .stopping
        pendingAutoStop = false
        // The clock and the meters stop the moment Stop is pressed, not when
        // the files have closed: a clock still running reads as still recording.
        stopTicker()
        Task {
            var m = snapshot
            let stoppedAt = Date()
            let duration = await recorder.stop()
            m.endedAt = stoppedAt
            m.duration = duration
            if m.hasAudio { Metrics.recorded(seconds: duration) }
            m.status = m.hasAudio ? .pending : .failed
            if !m.hasAudio { m.error = L("Empty recording") }
            // Two numbers from two different places: samples counted, and the
            // clock. They disagree only when something converted the audio by
            // the wrong ratio, and nothing else in Ata would ever notice — the
            // file is a valid WAV either way, it just plays at the wrong speed
            // and transcribes to nonsense.
            if let began = startedAt {
                let ran = stoppedAt.timeIntervalSince(began)
                if recorder.paces.isEmpty {
                    if AudioCheck.isSuspect(audioSeconds: duration, elapsed: ran) {
                        NSLog("%@", AudioCheck.report(audioSeconds: duration, elapsed: ran,
                                                      formats: recorder.formatsSeen))
                    }
                } else {
                    for pace in recorder.paces {
                        // The ratio that matters is samples per second of host
                        // time, before silence was written to fill the gap. A
                        // file that matches the clock can still be double speed.
                        if let ratio = pace.deliveryRatio, abs(ratio - 1) > AudioCheck.tolerance {
                            NSLog("%@", AudioCheck.deliveryReport(track: pace.track, ratio: ratio,
                                                                  corrected: pace.corrected,
                                                                  formats: pace.formats))
                        } else if let host = pace.hostSeconds,
                                  AudioCheck.isSuspect(audioSeconds: pace.fileSeconds, elapsed: host) {
                            NSLog("%@", AudioCheck.report(audioSeconds: pace.fileSeconds, elapsed: host,
                                                          formats: pace.formats))
                        }
                    }
                }
            }
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
        stopTicker()
        Task {
            _ = await recorder.stop()
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
            Metrics.recorded(seconds: duration)
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
                self.live.now = Date()
                self.live.micLevel = self.recorder.micLevel
                self.live.systemLevel = self.recorder.systemLevel
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
        live.micLevel = 0
        live.systemLevel = 0
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
        guard m.hasAudio, !m.isPlaceholder, m.id != transcribingID, m.id != current?.id,
              !audioJobs.contains(m.id), m.canClaim() else { return }
        m.status = .pending
        m.error = nil
        m.override = override
        Library.save(m)
        reload()
        pump()
    }

    func delete(_ m: Meeting) {
        guard m.id != current?.id, m.id != transcribingID, !audioJobs.contains(m.id) else { return }
        // Its voices go only with it: a meeting still there keeps them.
        if Library.trash(m) {
            PeopleModel.shared.removeMeeting(m.id)
        } else {
            lastError = L("Could not delete this meeting.")
        }
        reload()
    }

    /// Transcribes the next pending meeting (oldest first), one at a time.
    /// With the folder shared, a meeting another device has claimed is
    /// skipped, and so is another device's whose audio hasn't arrived yet.
    ///
    /// Finding the next one reads every meeting folder, so it happens off the
    /// main actor; one search at a time, and a call meanwhile searches again after.
    private func pump() {
        // Not while the library is being copied into iCloud: it moves once nothing uses it.
        guard transcribingID == nil, !CloudSync.shared.copying else { return }
        guard !pumping else { pumpAgain = true; return }
        pumping = true
        let repairing = repairingIDs
        Task {
            let next = await Task.detached(priority: .userInitiated) {
                Self.nextInQueue(Library.loadAll(), repairing: repairing, now: Date())
            }.value
            pumping = false
            if let next { startTranscribing(next) }
            if pumpAgain {
                pumpAgain = false
                pump()
            }
        }
    }

    /// The meeting the queue takes next: the oldest one waiting (the list is newest first).
    nonisolated static func nextInQueue(_ all: [Meeting], repairing: Set<String>, now: Date) -> Meeting? {
        all.last { !repairing.contains($0.id) && RunEnd.awaits($0, now: now) && ($0.isMine || $0.hasAudio) }
    }

    private func startTranscribing(_ found: Meeting) {
        // Things moved while the search ran: something else started, or the
        // repair scan took this meeting back.
        guard transcribingID == nil, !CloudSync.shared.copying, !repairingIDs.contains(found.id) else { return }
        var m = found

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
        }

        transcribingID = m.id
        live.transcribeProgress = 0
        m.status = .transcribing
        m.override = nil
        m.claim = Claim(device: Device.current, at: Date())
        Library.save(m)
        reload()
        let job = m

        transcribeJob = Task {
            let heartbeat = renewClaim(of: job.id)
            // Saved onto meeting.json as it is now, and only while the claim is still this
            // run's (see `RunEnd`): a device that took it over owns the meeting, so nothing
            // here is saved and its audio is left alone.
            do {
                let outcome = try await Transcriber.transcribe(job, options: options) { p in
                    Task { @MainActor in
                        if AppStore.shared.transcribingID == job.id { AppStore.shared.live.setProgress(p) }
                    }
                }
                if let m = await RunEnd.save(job.id, as: .done, apply: RunEnd.done(outcome)) {
                    if SummaryBackfill.shouldMark(summarize: options.summarize, appleAvailable: AppleModel.isAvailable,
                                                  words: m.transcriptions?.last?.words ?? 0) {
                        var owed = m
                        owed.summaryPending = true
                        Library.save(owed)
                    }
                    Notifier.shared.transcriptReady(m)
                    self.finishAudio(of: m)
                }
            } catch TranscriberError.cancelled {
                // Stopped because Ata is quitting: back in the queue for the next launch,
                // still claimed, so another device only takes it if this one stays away.
                _ = await RunEnd.save(job.id, as: .pending)
            } catch let error where RunEnd.releasesClaim(error) {
                // The audio is still in iCloud: the device that has it may do it instead.
                RunEnd.retryLater(job.id)
                _ = await RunEnd.save(job.id, as: .pending) { $0.claim = nil }
            } catch {
                let message = error.localizedDescription
                if let m = await RunEnd.save(job.id, as: .failed, apply: { m in
                    m.error = message
                    m.claim = nil
                }) {
                    Notifier.shared.transcriptFailed(m, error: message)
                }
            }
            heartbeat.cancel()
            transcribeJob = nil
            transcribingID = nil
            live.transcribeProgress = 0
            reload()
            pump()
        }
    }

    /// Renews this device's claim on the meeting being transcribed every few
    /// minutes, so a long run is never taken for an abandoned one. If another
    /// device took it over meanwhile (this Mac slept past the claim), the run stops.
    private func renewClaim(of id: String) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                guard !Task.isCancelled, transcribingID == id, var fresh = Library.load(id) else { return }
                // meeting.json is still coming down from iCloud: renewed next time round.
                if fresh.isPlaceholder { continue }
                guard fresh.status == .transcribing, fresh.isClaimed() else {
                    NSLog("Ata: another device took over \(id); this Mac stops transcribing it")
                    transcribeJob?.cancel()
                    return
                }
                fresh.claim = Claim(device: Device.current, at: Date())
                Library.save(fresh)
            }
        }
    }

    /// Runs `handleAudio` beside the queue instead of in it. Writing the MP3
    /// and compressing two hour-long tracks took minutes after the transcript
    /// was already saved, and the next meeting waited behind them.
    private func finishAudio(of m: Meeting) {
        guard m.isMine else { return }
        audioJobs.insert(m.id)
        Task {
            await handleAudio(of: m)
            audioJobs.remove(m.id)
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
            for url in m.audioFilesToDiscard { try? Coordinated.remove(url) }
            return
        }
        guard Pref.d.bool(forKey: Pref.compressAudio) else { return }
        for wav in [m.micURL, m.systemURL] where Paths.fileSize(wav) > 44 {
            _ = await AudioFiles.compressToM4A(wav)
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

    /// Why nothing is happening to a queued meeting, when something is stopping it.
    var queueReason: String? {
        QueueReason.text(whisper: setup.whisper, model: setup.model,
                         progress: setup.downloadProgress, error: setup.downloadError)
    }

    /// Writes the summaries owed from when Apple Intelligence was off, one at a
    /// time. Tried once per launch: one that fails keeps failing until something changes.
    func writeOwedSummaries() {
        guard AppleModel.isAvailable, !writingOwedSummaries else { return }
        let owed = meetings.filter { $0.summaryPending == true && !triedOwedSummaries.contains($0.id) }
        guard !owed.isEmpty else { return }
        writingOwedSummaries = true
        Task {
            defer { writingOwedSummaries = false; reload() }
            for m in owed {
                triedOwedSummaries.insert(m.id)
                guard let stored = StoredTranscript.load(from: m.storedTranscriptURL) else { continue }
                let options = TranscribeOptions.current()
                if stored.summary == nil {
                    let draft = Transcriber.render(stored, meeting: m, names: Speakers.names(for: m, myName: options.myName))
                    guard let text = await Summarizer.summarize(markdown: draft, options: options),
                          (try? MeetingNotes.addSummary(text, to: m, myName: options.myName)) != nil else { continue }
                }
                if var fresh = Library.load(m.id) {
                    fresh.summaryPending = nil
                    Library.save(fresh)
                }
            }
        }
    }

    /// Once setup is complete, work through whatever is queued.
    func setupChanged() {
        setup.refresh()
        writeOwedSummaries()
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
        live.now = now
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
        live.micLevel = mic
        live.systemLevel = system
        self.transcribingID = transcribingID
        live.transcribeProgress = progress
        detectedApp = nil
        warning = nil
        lastError = nil
        meetings = Library.loadAll()
    }
}

/// What changes several times a second: the recording clock, the two meters
/// and the transcription's progress. Only the views that show one of them
/// observe this, so a tick redraws a clock, not the whole popover.
@MainActor
final class LiveValues: ObservableObject {
    static let shared = LiveValues()

    @Published var now = Date()
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var transcribeProgress: Double = 0

    /// Only when the whole percent shown changes: engines report far more often.
    func setProgress(_ p: Double) {
        guard Self.percent(p) != Self.percent(transcribeProgress) else { return }
        transcribeProgress = p
    }

    nonisolated static func percent(_ p: Double) -> Int { Int((max(0, min(1, p)) * 100).rounded(.down)) }
}

enum AVAuthorization {
    static var micUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }
}
