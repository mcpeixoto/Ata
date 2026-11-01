import Foundation

/// Scratch audio for a mixed-language pass (`languages-XXXXXXXX/` inside a
/// meeting folder). Removed when the pass finishes; a crash used to leave it.
enum LanguagePieces {
    static func remove(in dir: URL) {
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for kid in kids where kid.lastPathComponent.hasPrefix("languages-") {
            try? FileManager.default.removeItem(at: kid)
        }
    }
}

/// Transcribes with whisper.cpp on the Mac's own GPU (Metal). Nothing leaves the machine.
///
/// whisper.cpp runs as a separate program (whisper-cli), which only a Mac can
/// start. On iPhone `Paths.whisperCLI()` is nil, so every entry point here
/// reports the engine as missing instead.
enum LocalEngine {
    #if os(macOS)
    /// Current whisper process, so it can be terminated when the app quits.
    nonisolated(unsafe) static var currentProcess: Process?
    #endif

    private static var threads: Int { max(4, ProcessInfo.processInfo.activeProcessorCount - 2) }

    /// Decoding settings, measured on real European Portuguese and English
    /// speech (clean, VoIP and phone quality; see docs/plans):
    /// - beam search 5 / best-of 5, pinned so a whisper.cpp update can't change them;
    /// - `-mc 0`: no text context carried between windows. With context on,
    ///   every model sometimes fell into a repetition loop (one inserted 788 words).
    /// No `--prompt`: it made loops more likely, and `-mc 0` ignores it anyway.
    static let decoding = ["-bs", "5", "-bo", "5", "-mc", "0"]

    /// Silero VAD, looser than whisper.cpp's defaults: short conversational
    /// turns had their first words clipped (VoIP meeting WER 32.0 → 22.7).
    static var vad: [String] {
        ["--vad", "-vm", Paths.vadModel.path, "-vt", "0.35", "-vp", "300", "-vsd", "500"]
    }

    /// Asks whisper which language a track is in, without transcribing it.
    /// Returns the language code and whisper's confidence, or nil.
    static func detectLanguage(audio: URL, model: LocalModel) async -> (code: String, p: Double)? {
        guard let cli = Paths.whisperCLI(), model.isInstalled else { return nil }
        var args = ["-m", model.path.path, "-f", audio.path, "-l", "auto", "-dl", "-t", String(threads)]
        if Paths.hasVADModel { args += vad }
        guard let log = try? await runProcess(cli, args, progress: { _ in }) else { return nil }
        return parseDetection(log)
    }

    /// The language of each file, from one whisper-cli run: it loads the model
    /// once and takes any number of `-f` files.
    static func detectLanguages(_ files: [URL], model: LocalModel) async -> [(code: String, p: Double)?] {
        guard let cli = Paths.whisperCLI(), model.isInstalled, !files.isEmpty else {
            return files.map { _ in nil }
        }
        var args = ["-m", model.path.path, "-l", "auto", "-dl", "-t", String(threads)]
        for f in files { args += ["-f", f.path] }
        if Paths.hasVADModel { args += vad }
        guard let log = try? await runProcess(cli, args, progress: { _ in }) else { return files.map { _ in nil } }
        return parseDetections(log, files: files)
    }

    /// Each file's detection, from the stretch of log after "processing '<file>'".
    /// A file that logged no detection gets nil rather than the next file's answer.
    static func parseDetections(_ log: String, files: [URL]) -> [(code: String, p: Double)?] {
        let starts = files.map { log.range(of: "processing '\($0.path)'")?.lowerBound }
        return files.indices.map { i in
            guard let start = starts[i] else { return nil }
            let end = starts[(i + 1)...].compactMap { $0 }.first ?? log.endIndex
            return parseDetection(String(log[start..<end]))
        }
    }

    /// Transcribes a track whose speaker may switch languages: cut at pauses,
    /// the language of each piece detected, and each run of one language
    /// transcribed in that language, times shifted back into the track.
    static func transcribeMixed(audio: URL, speaker: String, model: LocalModel, fallback: String,
                                plausible: [String], progress: @escaping @Sendable (Double) -> Void)
        async throws -> [Segment] {
        let pieces = try SpeechChunks.split(audio)
        guard pieces.count > 1 else {
            return try await transcribe(audio: audio, speaker: speaker, model: model, language: fallback,
                                        progress: progress)
        }
        let dir = audio.deletingLastPathComponent()
            .appendingPathComponent("languages-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var files: [URL] = []
        for (i, range) in pieces.enumerated() {
            let file = dir.appendingPathComponent("piece-\(i).wav")
            try AudioFiles.copySamples(audio, range, to: file)
            files.append(file)
        }
        progress(0.02)
        let detections = await detectLanguages(files, model: model)
        let rate = Double(WavWriter.sampleRate)
        let runs = LanguageChoice.runs(detections, seconds: pieces.map { Double($0.count) / rate },
                                       plausible: plausible, fallback: fallback)
        progress(0.1)
        if Task.isCancelled { throw TranscriberError.cancelled }
        if runs.count == 1 {
            return try await transcribe(audio: audio, speaker: speaker, model: model, language: runs[0].language) {
                progress(0.1 + 0.9 * $0)
            }
        }

        let total = Double(pieces.last!.upperBound)
        var out: [Segment] = []
        for (i, run) in runs.enumerated() {
            // Language detection swallows a cancelled run as "no answer";
            // the pieces after it must not start.
            if Task.isCancelled { throw TranscriberError.cancelled }
            let range = pieces[run.pieces.lowerBound].lowerBound..<pieces[run.pieces.upperBound - 1].upperBound
            let file = dir.appendingPathComponent("run-\(i).wav")
            try AudioFiles.copySamples(audio, range, to: file)
            let offset = range.lowerBound * 1000 / Int(WavWriter.sampleRate)
            let before = Double(range.lowerBound) / total, share = Double(range.count) / total
            let segments = try await transcribe(audio: file, speaker: speaker, model: model, language: run.language) {
                progress(0.1 + 0.9 * (before + share * $0))
            }
            out += segments.map { $0.shifted(by: offset) }
        }
        return out
    }

    /// "whisper_full_with_state: auto-detected language: pt (p = 0.973118)"
    static func parseDetection(_ log: String) -> (code: String, p: Double)? {
        guard let r = log.range(of: #"auto-detected language: ([a-z]{2,3}) \(p = ([0-9.]+)\)"#,
                                options: .regularExpression) else { return nil }
        let match = String(log[r])
        let parts = match.replacingOccurrences(of: "auto-detected language: ", with: "")
            .replacingOccurrences(of: "(p = ", with: "").replacingOccurrences(of: ")", with: "")
            .split(separator: " ")
        guard parts.count == 2, let p = Double(parts[1]) else { return nil }
        return (String(parts[0]), p)
    }

    static func transcribe(audio: URL, speaker: String, model: LocalModel, language: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        guard let cli = Paths.whisperCLI() else { throw TranscriberError.whisperMissing }
        guard model.isInstalled else { throw TranscriberError.modelMissing }

        let outBase = audio.deletingPathExtension().appendingPathExtension("whisper")
        let jsonURL = outBase.appendingPathExtension("json")
        try? FileManager.default.removeItem(at: jsonURL)

        let base = [
            "-m", model.path.path,
            "-f", audio.path,
            "-l", language,
            "-t", String(threads),
            // Full JSON: segments plus per-token timings, for splitting by speaker.
            "-ojf", "-of", outBase.path,
            "-pp",
        ] + decoding
        let useVAD = Paths.hasVADModel

        do {
            _ = try await runProcess(cli, useVAD ? base + vad : base, progress: progress)
        } catch TranscriberError.cancelled {
            throw TranscriberError.cancelled
        } catch where useVAD {
            // Older whisper.cpp builds have no VAD support: retry without it.
            _ = try await runProcess(cli, base, progress: progress)
        }

        guard let data = try? Data(contentsOf: jsonURL) else {
            throw TranscriberError.failed(L("produced no output"))
        }
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        // whisper sometimes cuts a UTF-8 character in half: normalize before parsing.
        let clean = Data(String(decoding: data, as: UTF8.self).utf8)
        let parsed = try JSONDecoder().decode(WhisperJSON.self, from: clean)
        return parsed.transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !Transcriber.isNoise(text) else { return nil }
            return Segment(speaker: speaker, start: item.offsets.from, end: item.offsets.to, text: text,
                           words: words(item.tokens ?? []))
        }
    }

    #if os(macOS)
    /// Kills a helper process that has gone quiet. whisper writes a progress
    /// line as it works, so minutes without one is not a slow file, it is a
    /// wedged process — and the transcription queue is one at a time, so a
    /// wedge there holds every later meeting hostage until the app is quit.
    final class ProcessWatchdog: @unchecked Sendable {
        static let stallLimit: TimeInterval = 10 * 60
        private let limit: TimeInterval
        private let lock = NSLock()
        private var lastActivity = Date()
        private var stalledFlag = false
        private var task: Task<Void, Never>?

        init(limit: TimeInterval = ProcessWatchdog.stallLimit) { self.limit = limit }

        func watch(_ process: Process) {
            noteActivity()
            let poll = min(15, max(0.01, limit / 4))
            task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                    guard let self, !Task.isCancelled else { return }
                    if self.idleTime() > self.limit {
                        self.markStalled()
                        if process.isRunning { process.terminate() }
                        return
                    }
                }
            }
        }

        func noteActivity() { lock.lock(); lastActivity = Date(); lock.unlock() }
        private func markStalled() { lock.lock(); stalledFlag = true; lock.unlock() }
        func stop() { task?.cancel(); task = nil }
        func didStall() -> Bool { lock.lock(); defer { lock.unlock() }; return stalledFlag }
        private func idleTime() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastActivity)
        }
    }
    #endif

    private final class LogBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    #if !os(macOS)
    @discardableResult
    static func runProcess(_ exe: URL, _ args: [String],
                           progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        throw TranscriberError.whisperMissing
    }
    #else
    /// The process a run started, for the cancellation handler, which can be
    /// called before the process exists, while it runs, or after it ended.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        /// False when the run was cancelled before the process could start.
        func set(_ p: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            process = p
            return true
        }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let p = process
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    /// Runs a helper to the end. Cancelling the calling task terminates it:
    /// another device taking a meeting over cancels the run, and a whisper left
    /// working on a meeting this Mac no longer owns held the one-at-a-time
    /// queue until it finished on its own.
    @discardableResult
    static func runProcess(_ exe: URL, _ args: [String],
                           progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        if Task.isCancelled { throw TranscriberError.cancelled }
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await startProcess(exe, args, box: box, progress: progress)
        } onCancel: {
            box.cancel()
        }
    }

    private static func startProcess(_ exe: URL, _ args: [String], box: ProcessBox,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.qualityOfService = .userInitiated
            let pipe = Pipe()
            p.standardError = pipe

            let log = LogBuffer()
            let watchdog = ProcessWatchdog()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                watchdog.noteActivity()
                log.append(d)
                // Lines like: "whisper_print_progress_callback: progress =  45%"
                let s = String(decoding: d, as: UTF8.self)
                if let r = s.range(of: #"progress\s*=\s*(\d+)%"#, options: [.regularExpression, .backwards]) {
                    let digits = s[r].filter(\.isNumber)
                    if let v = Double(digits) { progress(min(1, v / 100)) }
                }
            }
            p.terminationHandler = { proc in
                watchdog.stop()
                pipe.fileHandleForReading.readabilityHandler = nil
                // Whatever was still buffered when the process exited.
                log.append(pipe.fileHandleForReading.readDataToEndOfFile())
                LocalEngine.currentProcess = nil
                if proc.terminationStatus == 0 {
                    cont.resume(returning: log.text)
                } else if watchdog.didStall() {
                    cont.resume(throwing: TranscriberError.failed(
                        L("The transcription stopped making progress and was stopped. Your audio is safe. Try again.")))
                } else if proc.terminationReason == .uncaughtSignal {
                    // Killed — Ata is quitting. Don't retry, or whisper outlives the app.
                    cont.resume(throwing: TranscriberError.cancelled)
                } else {
                    // The detail is for the log. Whisper's own last lines mean nothing to the reader.
                    let tail = log.text.split(separator: "\n").suffix(4).joined(separator: "\n")
                    NSLog("Ata: whisper-cli exited with %d: %@", proc.terminationStatus, tail)
                    cont.resume(throwing: TranscriberError.failed(
                        L("The transcription stopped unexpectedly. Your audio is safe. Try again.")))
                }
            }
            guard box.set(p) else {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: TranscriberError.cancelled)
                return
            }
            do {
                try p.run()
                LocalEngine.currentProcess = p
                watchdog.watch(p)
                // Cancelled between handing the process over and starting it.
                if box.isCancelled { p.terminate() }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
    }
    #endif

    /// Turns Whisper's tokens into words: a token starting with a space starts a
    /// word, any other continues the previous one (sub-word pieces and
    /// punctuation), and control tokens such as [_BEG_] are dropped.
    static func words(_ tokens: [Token]) -> [Segment.Word] {
        var out: [Segment.Word] = []
        for t in tokens {
            if t.text.hasPrefix("[_") || t.text.hasPrefix("<|") || t.text.isEmpty { continue }
            if t.text.hasPrefix(" ") || out.isEmpty {
                let text = t.text.trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                out.append(.init(start: t.offsets.from, end: t.offsets.to, text: text))
            } else {
                let last = out.removeLast()
                out.append(.init(start: last.start, end: max(last.end, t.offsets.to), text: last.text + t.text))
            }
        }
        return out
    }

    struct Token: Decodable {
        struct Offsets: Decodable { let from: Int; let to: Int }
        let text: String
        let offsets: Offsets
    }

    private struct WhisperJSON: Decodable {
        struct Item: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
            let tokens: [Token]?
        }
        let transcription: [Item]
    }
}
