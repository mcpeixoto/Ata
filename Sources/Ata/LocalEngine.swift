import Foundation

/// Transcribes with whisper.cpp on the Mac's own GPU (Metal). Nothing leaves the machine.
enum LocalEngine {
    /// Current whisper process, so it can be terminated when the app quits.
    nonisolated(unsafe) static var currentProcess: Process?

    static func transcribe(audio: URL, speaker: String, language: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        guard let cli = Paths.whisperCLI() else { throw TranscriberError.whisperMissing }
        guard Paths.hasWhisperModel else { throw TranscriberError.modelMissing }

        let outBase = audio.deletingPathExtension().appendingPathExtension("whisper")
        let jsonURL = outBase.appendingPathExtension("json")
        try? FileManager.default.removeItem(at: jsonURL)

        let threads = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        var args = [
            "-m", Paths.whisperModel.path,
            "-f", audio.path,
            "-l", language,
            "-t", String(threads),
            "-oj", "-of", outBase.path,
            "-pp",
        ]
        let useVAD = Paths.hasVADModel
        if useVAD { args += ["--vad", "-vm", Paths.vadModel.path] }

        do {
            try await runProcess(cli, args, progress: progress)
        } catch where useVAD {
            // Older whisper.cpp builds have no VAD support: retry without it.
            args.removeLast(3)
            try await runProcess(cli, args, progress: progress)
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
            return Segment(speaker: speaker, start: item.offsets.from, end: item.offsets.to, text: text)
        }
    }

    private final class LogBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private static func runProcess(_ exe: URL, _ args: [String],
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
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
                LocalEngine.currentProcess = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
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

    private struct WhisperJSON: Decodable {
        struct Item: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Item]
    }
}
