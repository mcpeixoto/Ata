import Foundation

/// Transcribes with whisper.cpp on the Mac's own GPU (Metal). Nothing leaves the machine.
enum LocalEngine {
    /// Current whisper process, so it can be terminated when the app quits.
    nonisolated(unsafe) static var currentProcess: Process?

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

    private final class LogBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    @discardableResult
    private static func runProcess(_ exe: URL, _ args: [String],
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
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                log.append(d)
                // Lines like: "whisper_print_progress_callback: progress =  45%"
                let s = String(decoding: d, as: UTF8.self)
                if let r = s.range(of: #"progress\s*=\s*(\d+)%"#, options: [.regularExpression, .backwards]) {
                    let digits = s[r].filter(\.isNumber)
                    if let v = Double(digits) { progress(min(1, v / 100)) }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Whatever was still buffered when the process exited.
                log.append(pipe.fileHandleForReading.readDataToEndOfFile())
                LocalEngine.currentProcess = nil
                if proc.terminationStatus == 0 {
                    cont.resume(returning: log.text)
                } else {
                    let tail = log.text.split(separator: "\n").suffix(4).joined(separator: "\n")
                    cont.resume(throwing: TranscriberError.failed(
                        tail.isEmpty ? L("exit code %d", proc.terminationStatus) : tail))
                }
            }
            do {
                try p.run()
                LocalEngine.currentProcess = p
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

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
