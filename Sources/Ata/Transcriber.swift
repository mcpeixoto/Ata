import Foundation

enum TranscriberError: LocalizedError {
    case whisperMissing, modelMissing, noAudio
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .whisperMissing: return L("The local transcription engine (whisper.cpp) is not installed.")
        case .modelMissing: return L("The transcription model has not been downloaded yet.")
        case .noAudio: return L("No audio was found for this meeting.")
        case .failed(let log): return L("Whisper failed: %@", log)
        }
    }
}

struct Segment {
    let speaker: String
    let start: Int // ms
    let end: Int   // ms
    let text: String
}

/// Which backend produces the transcript.
enum Engine: String, CaseIterable {
    /// whisper.cpp on this Mac. Nothing leaves the machine.
    case local
    /// OpenAI's transcription API. Audio is uploaded.
    case openAI = "openai"

    var isLocal: Bool { self == .local }

    static var current: Engine {
        Engine(rawValue: Pref.d.string(forKey: Pref.engine) ?? Engine.local.rawValue) ?? .local
    }
}

/// Everything the transcription job needs, captured when the job is queued so
/// changing a setting mid-run cannot alter a transcript already in flight.
struct TranscribeOptions {
    var engine: Engine
    var myName: String
    var language: String
    var openAIModel: String
    var summarize: Bool
    var summaryModel: String

    static func current() -> TranscribeOptions {
        TranscribeOptions(
            engine: Engine.current,
            myName: Pref.d.string(forKey: Pref.myName) ?? L("Me"),
            language: Pref.d.string(forKey: Pref.language) ?? "auto",
            openAIModel: Pref.d.string(forKey: Pref.openAIModel) ?? Pref.defaultOpenAIModel,
            summarize: Pref.d.bool(forKey: Pref.summarize),
            summaryModel: Pref.d.string(forKey: Pref.summaryModel) ?? Pref.defaultSummaryModel)
    }
}

/// Runs a transcription end to end: picks the engine per track, merges the two
/// tracks into one timeline, drops microphone echo and writes the Markdown.
enum Transcriber {
    static func transcribe(_ meeting: Meeting, options: TranscribeOptions,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let others = L("Others")

        // Only tracks with at least ~0.5 s of audio are worth sending to an engine.
        var prepared: [(speaker: String, audio: URL, temporary: Bool)] = []
        defer {
            for track in prepared where track.temporary {
                try? FileManager.default.removeItem(at: track.audio)
            }
        }
        for (speaker, source) in [(options.myName, meeting.micAudioURL), (others, meeting.systemAudioURL)] {
            guard let source, Paths.fileSize(source) > 1_000 else { continue }
            if source.pathExtension.lowercased() == "wav" {
                prepared.append((speaker, source, false))
            } else {
                // The WAV was compressed after an earlier run: decode it back.
                let temp = source.deletingPathExtension().appendingPathExtension("decoded.wav")
                try AudioFiles.decodeToWAV(source, to: temp)
                prepared.append((speaker, temp, true))
            }
        }
        guard !prepared.isEmpty else { throw TranscriberError.noAudio }

        var segments: [Segment] = []
        var coarse = false
        for (i, track) in prepared.enumerated() {
            let base = Double(i) / Double(prepared.count)
            let span = 1 / Double(prepared.count)
            let step: @Sendable (Double) -> Void = { p in progress(base + p * span) }

            switch options.engine {
            case .local:
                segments += try await LocalEngine.transcribe(audio: track.audio, speaker: track.speaker,
                                                             language: options.language, progress: step)
            case .openAI:
                let result = try await OpenAIEngine.transcribe(audio: track.audio, speaker: track.speaker,
                                                               language: options.language,
                                                               model: options.openAIModel, progress: step)
                segments += result.segments
                coarse = coarse || result.coarse
            }
        }

        // Echo removal compares what both tracks said at the same moment, so it
        // needs real timestamps.
        if !coarse {
            segments = removeEcho(segments, me: options.myName)
        }

        var md = render(segments, meeting: meeting, options: options, coarse: coarse)

        if options.summarize, !segments.isEmpty {
            if let summary = await Summarizer.summarize(markdown: md, options: options) {
                md = insertSummary(summary, into: md)
            }
        }
        // No summary (disabled, or the call failed): leave no marker behind.
        md = md.replacingOccurrences(of: summaryPlaceholder + "\n\n", with: "")
            .replacingOccurrences(of: summaryPlaceholder, with: "")

        try md.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)
        return meeting.transcriptURL
    }

    static func isNoise(_ t: String) -> Bool {
        let wrapped = (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")"))
            || (t.hasPrefix("*") && t.hasSuffix("*"))
        return wrapped || ["...", "…", "-", "."].contains(t)
    }

    // MARK: - Echo

    /// Without headphones the microphone picks up the other participants, so the
    /// same sentence shows up twice, once attributed to you. Drop microphone
    /// segments that repeat almost word for word what the others said at the same time.
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

    private static func render(_ segments: [Segment], meeting: Meeting,
                               options: TranscribeOptions, coarse: Bool) -> String {
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
        df.locale = .autoupdatingCurrent
        df.dateStyle = .long
        df.timeStyle = .short

        var md = "# \(meeting.title) — \(df.string(from: meeting.startedAt))\n\n"
        var info: [String] = []
        if let d = meeting.duration {
            info.append(L("Duration: %d min", max(1, Int((d / 60).rounded()))))
        }
        info.append(L("Participants: %@, %@", options.myName, L("Others")))
        md += info.joined(separator: " · ") + "\n\n" + summaryPlaceholder + "\n\n---\n\n"

        if blocks.isEmpty {
            md += L("_No speech was detected in this recording._") + "\n"
        }
        for b in blocks {
            md += coarse
                ? "**\(b.speaker):** \(b.text)\n\n"
                : "**[\(timestamp(b.start))] \(b.speaker):** \(b.text)\n\n"
        }
        md += "---\n"
        md += options.engine.isLocal
            ? "_" + L("Transcribed locally by Ata.") + "_\n"
            : "_" + L("Transcribed by Ata with OpenAI (%@).", options.openAIModel) + "_\n"
        return md
    }

    /// Marker that `insertSummary` replaces, so the summary lands above the transcript.
    private static let summaryPlaceholder = "<!-- ata:summary -->"

    private static func insertSummary(_ summary: String, into markdown: String) -> String {
        let block = "## " + L("Summary") + "\n\n" + summary
        if markdown.contains(summaryPlaceholder) {
            return markdown.replacingOccurrences(of: summaryPlaceholder, with: block)
        }
        return markdown + "\n\n" + block + "\n"
    }

    private static func timestamp(_ ms: Int) -> String {
        let s = ms / 1000
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}
