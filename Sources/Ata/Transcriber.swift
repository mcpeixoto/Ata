import Foundation

enum TranscriberError: LocalizedError {
    case whisperMissing, modelMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .whisperMissing: return "O motor de transcrição (whisper.cpp) não está instalado."
        case .modelMissing: return "O modelo de transcrição ainda não foi descarregado."
        case .failed(let log): return "O Whisper falhou: \(log)"
        }
    }
}

struct Segment {
    let speaker: String
    let start: Int // ms
    let end: Int   // ms
    let text: String
}

/// Transcreve localmente com o whisper.cpp (GPU do Mac via Metal). Nada sai do computador.
enum Transcriber {
    /// Processo atual, para o podermos terminar se a app fechar.
    static var currentProcess: Process?

    static func transcribe(_ meeting: Meeting, myName: String, language: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let cli = Paths.whisperCLI() else { throw TranscriberError.whisperMissing }
        guard Paths.hasWhisperModel else { throw TranscriberError.modelMissing }

        // Pistas com pelo menos ~0.5 s de áudio.
        let tracks = [(myName, meeting.micURL), ("Outros", meeting.systemURL)]
            .filter { Paths.fileSize($0.1) > 44 + 16_000 }

        var segments: [Segment] = []
        for (i, track) in tracks.enumerated() {
            let base = Double(i) / Double(max(tracks.count, 1))
            let span = 1 / Double(max(tracks.count, 1))
            segments += try await run(cli: cli, audio: track.1, speaker: track.0, language: language) { p in
                progress(base + p * span)
            }
        }

        segments = removeEcho(segments, me: myName)
        let md = render(segments, meeting: meeting, myName: myName)
        try md.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)
        return meeting.transcriptURL
    }

    // MARK: - whisper.cpp

    private static func run(cli: URL, audio: URL, speaker: String, language: String,
                            progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
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
            // Versões antigas do whisper.cpp não têm VAD: tentar de novo sem.
            args.removeLast(3)
            try await runProcess(cli, args, progress: progress)
        }

        guard let data = try? Data(contentsOf: jsonURL) else {
            throw TranscriberError.failed("não produziu resultado")
        }
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        // O whisper às vezes corta caracteres UTF-8 a meio: normalizar antes do parse.
        let clean = Data(String(decoding: data, as: UTF8.self).utf8)
        let parsed = try JSONDecoder().decode(WhisperJSON.self, from: clean)
        return parsed.transcription.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNoise(text) else { return nil }
            return Segment(speaker: speaker, start: item.offsets.from, end: item.offsets.to, text: text)
        }
    }

    private static func isNoise(_ t: String) -> Bool {
        let wrapped = (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")"))
            || (t.hasPrefix("*") && t.hasSuffix("*"))
        return wrapped || ["...", "…", "-", "."].contains(t)
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
                // Linhas tipo: "whisper_print_progress_callback: progress =  45%"
                let s = String(decoding: d, as: UTF8.self)
                if let r = s.range(of: #"progress\s*=\s*(\d+)%"#, options: [.regularExpression, .backwards]) {
                    let digits = s[r].filter(\.isNumber)
                    if let v = Double(digits) { progress(min(1, v / 100)) }
                }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                Transcriber.currentProcess = nil
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let tail = log.text.split(separator: "\n").suffix(4).joined(separator: "\n")
                    cont.resume(throwing: TranscriberError.failed(tail.isEmpty ? "código \(proc.terminationStatus)" : tail))
                }
            }
            do {
                try p.run()
                Transcriber.currentProcess = p
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

    // MARK: - Eco

    /// Sem auscultadores, o micro apanha a voz dos outros e aparece em duplicado como "eu".
    /// Remove segmentos do micro que repetem quase palavra a palavra o que os outros disseram ao mesmo tempo.
    private static func removeEcho(_ segments: [Segment], me: String) -> [Segment] {
        let others = segments.filter { $0.speaker != me }
        guard !others.isEmpty else { return segments }
        return segments.filter { s in
            guard s.speaker == me else { return true }
            let mine = words(s.text)
            guard mine.count >= 3 else {
                return !others.contains { overlaps($0, s) && words($0.text).isSuperset(of: mine) }
            }
            return !others.contains { o in
                guard overlaps(o, s) else { return false }
                let theirs = words(o.text)
                let common = Double(mine.intersection(theirs).count)
                return common / Double(mine.count) > 0.6
            }
        }
    }

    private static func overlaps(_ a: Segment, _ b: Segment) -> Bool {
        a.start < b.end + 1500 && b.start < a.end + 1500
    }

    private static func words(_ t: String) -> Set<String> {
        Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    // MARK: - Markdown

    private static func render(_ segments: [Segment], meeting: Meeting, myName: String) -> String {
        var blocks: [Segment] = []
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if let last = blocks.last, last.speaker == s.speaker, s.start - last.end < 2_500 {
                blocks[blocks.count - 1] = Segment(speaker: last.speaker, start: last.start,
                                                   end: s.end, text: last.text + " " + s.text)
            } else {
                blocks.append(s)
            }
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "pt_PT")
        df.dateFormat = "d 'de' MMMM 'de' yyyy, HH:mm"

        var md = "# \(meeting.title) — \(df.string(from: meeting.startedAt))\n\n"
        var info: [String] = []
        if let d = meeting.duration { info.append("Duração: \(max(1, Int((d / 60).rounded()))) min") }
        info.append("Participantes: \(myName), Outros")
        md += info.joined(separator: " · ") + "\n\n---\n\n"

        if blocks.isEmpty {
            md += "_Não foi detetada fala nesta gravação._\n"
        }
        for b in blocks {
            md += "**[\(timestamp(b.start))] \(b.speaker):** \(b.text)\n\n"
        }
        md += "---\n_Transcrito localmente pela Ata._\n"
        return md
    }

    private static func timestamp(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
