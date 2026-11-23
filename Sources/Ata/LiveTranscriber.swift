import Foundation

/// One track of a recording that is still being written. `frames` is how many
/// samples are on disk now; chunks never read past it, so a pause in capture
/// does not open a hole in the coverage.
struct LiveTrack: Sendable {
    var speaker: String
    var url: URL
    var frames: @Sendable () -> Int
}

/// What live transcription has finished, saved as `live.json` beside the tracks.
/// The final pass trusts it only when the engine, model and language still match
/// and the coverage fits inside every track. Anything else is a full transcription.
struct LiveState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var engine: String
    var model: String
    var language: String
    /// Samples transcribed, from the start of every track. The next chunk,
    /// and the final pass's tail, begin here.
    var coveredUntilFrame: Int
    /// Speaker label → language code, detected once on the first chunk when
    /// the setting is automatic.
    var languages: [String: String]
    var segments: [Segment]

    /// False when this file must not stand in for a transcription: the user
    /// asked for a full run, the settings changed, or the coverage runs off
    /// the end of a track (the file and the audio disagree).
    func matches(options: TranscribeOptions, trackFrames: [Int]) -> Bool {
        guard options.useLiveState, version == Self.currentVersion else { return false }
        guard engine == options.engine.rawValue, model == options.modelID,
              language == options.language else { return false }
        guard coveredUntilFrame >= 0 else { return false }
        return trackFrames.allSatisfy { coveredUntilFrame <= $0 }
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Coordinated.write(encoder.encode(self), to: url)
    }

    /// Nil when the file is missing, still in iCloud, or not this shape.
    /// A missing file is a full transcription, not a failure.
    static func load(from url: URL) -> LiveState? {
        guard let file = CloudFiles.readable(url), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(LiveState.self, from: data)
    }
}

/// Where to cut a live chunk. The same sample on every track, inside audio
/// that has actually been written, on a pause when the tail has one.
enum LiveCut {
    /// A chunk needs at least a minute of audio the final pass would otherwise do.
    static let minNewFrames = 60 * Int(WavWriter.sampleRate)
    /// The pause is looked for in the last 20 s before the shortest track.
    static let tailFrames = 20 * Int(WavWriter.sampleRate)
    /// The final pass transcribes a tail shorter than this itself; copying it
    /// out is not worth a model load.
    static let minTailFrames = Int(0.5 * WavWriter.sampleRate)

    /// The sample where this chunk ends, or nil when there is not a minute of
    /// new audio. `tail` is the PCM ending at `written` (the last 20 s, or less).
    /// The cut is never past `written`: the file's header lags the samples, and
    /// reading further would transcribe silence that has not been recorded.
    static func choose(written: Int, coveredUntil: Int, tail: [Int16]) -> Int? {
        guard written > coveredUntil, written - coveredUntil >= minNewFrames else { return nil }
        let count = min(max(tail.count, 0), written)
        guard count > 0 else { return nil }
        let samples = Array(tail.suffix(count))
        let tailStart = written - count
        let db = envelope(samples)
        guard !db.isEmpty else { return nil }

        let frameIndex = lastPause(in: db) ?? quietest(db)
        var sample = tailStart + frameIndex * SpeechChunks.frame
        if sample > written { sample = written }
        guard sample > coveredUntil else { return nil }
        return sample
    }

    /// Middle of the last quiet run of at least `SpeechChunks.pauseFrames`,
    /// including a run that reaches the live edge. `SpeechChunks.split` drops
    /// that trailing run on purpose (it glues a short tail to the piece before
    /// it); here the edge is exactly where we want to stop.
    private static func lastPause(in db: [Double]) -> Int? {
        guard !db.isEmpty else { return nil }
        let threshold = db.sorted()[db.count * 9 / 10] - 20
        var pauses: [Int] = []
        var run = 0
        for (f, v) in db.enumerated() {
            if v < threshold {
                run += 1
            } else {
                if run >= SpeechChunks.pauseFrames { pauses.append(f - run / 2) }
                run = 0
            }
        }
        if run >= SpeechChunks.pauseFrames { pauses.append(db.count - run / 2) }
        return pauses.last
    }

    private static func quietest(_ db: [Double]) -> Int {
        db.indices.min { db[$0] < db[$1] } ?? 0
    }

    /// Energy in dB, one value per `SpeechChunks.frame` samples. The same sum
    /// `SpeechChunks.split` uses; that function memory-maps its whole file, so
    /// a recording still being written is copied first and measured here.
    private static func envelope(_ samples: [Int16]) -> [Double] {
        let frame = SpeechChunks.frame
        let frames = samples.count / frame
        guard frames > 0 else { return [] }
        var db = [Double](repeating: -100, count: frames)
        for f in 0..<frames {
            var sum = 0.0
            for i in (f * frame)..<((f + 1) * frame) {
                let v = Double(samples[i]) / 32_768
                sum += v * v
            }
            db[f] = 10 * log10(sum / Double(frame) + 1e-10)
        }
        return db
    }

    static func readPCM(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        let count = max(0, (data.count - 44) / 2)
        var out = [Int16](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            guard count > 0, let base = raw.baseAddress else { return }
            let pcm = base.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for i in 0..<count { out[i] = Int16(littleEndian: pcm[i]) }
        }
        return out
    }
}

/// Samples in a 16 kHz mono 16-bit WAV, counted from the file size. The header's
/// own length is rewritten every few seconds while recording and is behind.
enum LiveAudio {
    static func samples(in url: URL) -> Int {
        let size = Paths.fileSize(url)
        return size > 44 ? Int((size - 44) / 2) : 0
    }
}

/// Transcribes finished stretches of a recording while it is still going, so
/// the final pass only has the tail left. Nothing in here is required: a chunk
/// that fails is forgotten, and the final pass transcribes whatever was not covered.
@MainActor
final class LiveTranscriber {
    /// What one chunk asks the engine for. Tests pass a fake; the app passes
    /// `Transcriber.transcribeTrack`.
    typealias Transcribe = @Sendable (URL, String, TranscribeOptions, String) async throws -> [Segment]

    private let interval: TimeInterval
    private let transcribe: Transcribe
    private let detect: @Sendable (URL, LocalModel) async -> (code: String, p: Double)?
    private let mayRun: @Sendable () -> Bool
    private let whisperBusy: @Sendable (String) -> Bool

    private var meetingID = ""
    private var soloMicrophone = false
    private var folder: URL?
    private var tracks: [LiveTrack] = []
    private var options = TranscribeOptions(engine: .local, myName: "", language: "en",
                                            localModel: "", summarize: false)
    private var state = LiveState(version: LiveState.currentVersion, engine: "", model: "", language: "",
                                  coveredUntilFrame: 0, languages: [:], segments: [])
    private var timer: Timer?
    private var work: Task<Void, Never>?

    /// How far the saved chunks reach. Tests read this; the final pass reads `live.json`.
    var coveredUntilFrame: Int { state.coveredUntilFrame }
    var segments: [Segment] { state.segments }

    init(interval: TimeInterval = 180,
         transcribe: Transcribe? = nil,
         detect: (@Sendable (URL, LocalModel) async -> (code: String, p: Double)?)? = nil,
         mayRun: (@Sendable () -> Bool)? = nil,
         whisperBusy: (@Sendable (String) -> Bool)? = nil) {
        self.interval = interval
        self.transcribe = transcribe ?? { @Sendable audio, speaker, options, language in
            try await Transcriber.transcribeTrack(audio: audio, speaker: speaker, options: options,
                                                  language: language, progress: { _ in })
        }
        self.detect = detect ?? { @Sendable url, model in
            await LocalEngine.detectLanguage(audio: url, model: model)
        }
        self.mayRun = mayRun ?? { @Sendable in LiveTranscriber.machineAllowsLiveWork() }
        self.whisperBusy = whisperBusy ?? { @Sendable in LiveTranscriber.otherWhisperRunning($0) }
    }

    /// Begins the timer. Safe to call once per recording; a `live.json` already
    /// in the folder (a relaunch mid-meeting) is continued, not restarted.
    func start(meeting: Meeting, folder: URL, tracks: [LiveTrack], options: TranscribeOptions) {
        meetingID = meeting.id
        soloMicrophone = meeting.soloMicrophone == true
        self.folder = folder
        self.tracks = tracks
        self.options = options
        let fresh = LiveState(version: LiveState.currentVersion, engine: options.engine.rawValue,
                              model: options.modelID, language: options.language,
                              coveredUntilFrame: 0, languages: [:], segments: [])
        if let saved = LiveState.load(from: folder.appendingPathComponent("live.json")),
           saved.engine == fresh.engine, saved.model == fresh.model, saved.language == fresh.language,
           saved.version == LiveState.currentVersion, saved.coveredUntilFrame >= 0 {
            state = saved
        } else {
            state = fresh
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.kick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One pass of the timer. Does nothing when a chunk is already running:
    /// chunks are never queued, a skipped tick is caught up later or by the final pass.
    func tick() async {
        kick()
        await work?.value
    }

    /// Cancels the chunk in flight, waits until it has stopped touching the
    /// folder, and writes `live.json`.
    func stop() async {
        timer?.invalidate()
        timer = nil
        let task = work
        task?.cancel()
        await task?.value
        work = nil
        save()
    }

    /// `live-XXXXXXXX/` directories a chunk or a crash left in a meeting folder.
    /// Never the tracks, and never `live.json`.
    nonisolated static func removeScratch(in folder: URL) {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return }
        for kid in kids where kid.lastPathComponent.hasPrefix("live-") {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: kid.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            try? fm.removeItem(at: kid)
        }
    }

    // MARK: Timer

    private func kick() {
        guard work == nil, !tracks.isEmpty, folder != nil else { return }
        guard mayRun() else { return }
        if options.engine == .local, whisperBusy(meetingID) { return }
        let written = tracks.map { $0.frames() }.min() ?? 0
        // A writer that has not caught up must not subtract through zero.
        guard written >= state.coveredUntilFrame + LiveCut.minNewFrames else { return }

        let job = Job(meetingID: meetingID, soloMicrophone: soloMicrophone, folder: folder!,
                      tracks: tracks, options: options, state: state)
        let transcribe = self.transcribe
        let detect = self.detect
        let task = Task.detached(priority: .utility) { [weak self] in
            let result = await Self.execute(job, transcribe: transcribe, detect: detect)
            await self?.apply(result)
        }
        work = task
    }

    private func apply(_ result: LiveState?) {
        if let result { state = result }
        work = nil
    }

    private func save() {
        guard let folder, state.coveredUntilFrame > 0 || !state.segments.isEmpty else { return }
        do {
            try state.save(to: folder.appendingPathComponent("live.json"))
        } catch {
            NSLog("Ata: could not save live transcription: \(error.localizedDescription)")
        }
    }

    /// Low Power Mode and a hot machine stay on the recording. The final pass
    /// runs either way, once the call is over.
    private nonisolated static func machineAllowsLiveWork() -> Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return false }
        switch info.thermalState {
        case .nominal, .fair: return true
        default: return false
        }
    }

    private nonisolated static func otherWhisperRunning(_ meetingID: String) -> Bool {
        #if os(macOS)
        WhisperProcesses.busyBesides(meetingID)
        #else
        false
        #endif
    }

    // MARK: One chunk

    private struct Job: Sendable {
        var meetingID: String
        var soloMicrophone: Bool
        var folder: URL
        var tracks: [LiveTrack]
        var options: TranscribeOptions
        var state: LiveState
    }

    /// Nil when the chunk did not count: not enough new audio, cancelled, or the
    /// engine failed. Coverage stays where the last successful chunk left it.
    private nonisolated static func execute(_ job: Job, transcribe: @escaping Transcribe,
                                            detect: @escaping @Sendable (URL, LocalModel) async -> (code: String, p: Double)?)
        async -> LiveState? {
        do {
            return try await WhisperScope.adopt(job.meetingID) {
                try await chunk(job, transcribe: transcribe, detect: detect)
            }
        } catch is CancellationError {
            return nil
        } catch TranscriberError.cancelled {
            return nil
        } catch {
            NSLog("Ata: live transcription chunk failed: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func chunk(_ job: Job, transcribe: Transcribe,
                                          detect: @Sendable (URL, LocalModel) async -> (code: String, p: Double)?)
        async throws -> LiveState? {
        if Task.isCancelled { return nil }
        let written = job.tracks.map { $0.frames() }.min() ?? 0
        guard let cut = try cutPoint(job, written: written) else { return nil }
        let range = job.state.coveredUntilFrame..<cut
        guard range.count >= LiveCut.minTailFrames else { return nil }

        let scratch = job.folder.appendingPathComponent("live-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var files: [String: URL] = [:]
        for track in job.tracks {
            let file = scratch.appendingPathComponent("\(track.speaker).wav")
            try AudioFiles.copySamples(track.url, range, to: file)
            guard LiveAudio.samples(in: file) == range.count else { return nil }
            files[track.speaker] = file
        }
        if let mic = files[Speakers.me], let system = files[Speakers.others] {
            files[Speakers.me] = try echoCancelled(mic, reference: system, in: scratch,
                                                   options: job.options, soloMicrophone: job.soloMicrophone) ?? mic
        }

        var languages = job.state.languages
        if job.options.engine == .local, job.options.language == "auto", languages.isEmpty {
            languages = await detectedLanguages(files, options: job.options, detect: detect)
        }
        if Task.isCancelled { return nil }

        let offset = range.lowerBound * 1000 / Int(WavWriter.sampleRate)
        var segments = job.state.segments
        for track in job.tracks {
            guard let file = files[track.speaker] else { continue }
            // The detected language is only the fallback: with the setting on
            // automatic, `transcribeTrack` still picks a language per stretch,
            // as the final pass does, since people switch mid-call.
            let language = languages[track.speaker] ?? job.options.language
            let spoken = try await transcribe(file, track.speaker, job.options, language)
            segments += spoken.map { $0.shifted(by: offset) }
        }
        if Task.isCancelled { return nil }

        var done = job.state
        done.languages = languages
        done.segments = segments
        done.coveredUntilFrame = range.upperBound
        try done.save(to: job.folder.appendingPathComponent("live.json"))
        return done
    }

    /// The cut, measured on a copy of the shortest track's last 20 s.
    /// `SpeechChunks.split` maps the whole file; this file is still growing.
    private nonisolated static func cutPoint(_ job: Job, written: Int) throws -> Int? {
        guard let probe = job.tracks.first else { return nil }
        let tailCount = min(LiveCut.tailFrames, written)
        guard tailCount > 0 else { return nil }
        let tailStart = written - tailCount
        // Beside the meeting folder, not in it: a crash must not leave a second mic.wav.
        let tailURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-live-tail-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tailURL) }
        try AudioFiles.copySamples(probe.url, tailStart..<written, to: tailURL)
        let pcm = try LiveCut.readPCM(tailURL)
        // A short read is the file not having those samples yet. Guessing a cut
        // from the bytes that did arrive would mark audio we never heard as done.
        guard pcm.count == tailCount else { return nil }
        return LiveCut.choose(written: written, coveredUntil: job.state.coveredUntilFrame, tail: pcm)
    }

    /// Same gate as the final pass, on this chunk's audio. A failure keeps the
    /// microphone chunk as it was recorded; the chunk is not abandoned.
    private nonisolated static func echoCancelled(_ mic: URL, reference: URL, in scratch: URL,
                                                  options: TranscribeOptions, soloMicrophone: Bool) throws -> URL? {
        let levels = try? Waveform.levels(reference)
        let audible = levels.map(SpeakerRoute.audibleSeconds) ?? 0
        guard Transcriber.cancelsEcho(options, audible: audible, soloMicrophone: soloMicrophone,
                                      systemLevels: levels) else { return nil }
        let cleaned = scratch.appendingPathComponent("mic-clean.wav")
        do {
            guard try EchoCanceller.clean(mic: mic, reference: reference, to: cleaned) != nil else {
                try? FileManager.default.removeItem(at: cleaned)
                return nil
            }
            return cleaned
        } catch {
            try? FileManager.default.removeItem(at: cleaned)
            NSLog("Ata: live echo cancellation failed, using the microphone as recorded: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated static func detectedLanguages(_ files: [String: URL], options: TranscribeOptions,
                                                      detect: @Sendable (URL, LocalModel) async -> (code: String, p: Double)?)
        async -> [String: String] {
        guard let model = LocalModel.find(options.localModel) else { return [:] }
        let speakers = files.keys.sorted()
        var detections: [(code: String, p: Double)?] = []
        for speaker in speakers {
            guard let file = files[speaker] else { continue }
            detections.append(await detect(file, model))
        }
        let picked = LanguageChoice.pick(detections, plausible: LanguageChoice.plausible)
        var out: [String: String] = [:]
        for (speaker, code) in zip(speakers, picked) { out[speaker] = code }
        return out
    }
}
