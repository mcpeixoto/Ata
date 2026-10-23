import AVFoundation
import CoreMedia
import Foundation
import NaturalLanguage
import Speech

/// Transcribes with Apple's on-device speech recognition (`SpeechAnalyzer`,
/// macOS 26 and iOS 26). Free, and nothing leaves the device; the language
/// model for each locale is downloaded once by the system, not by Ata.
///
/// Safe to call on every OS version: before 26 it throws `.unavailable`, so a
/// meeting queued with this engine fails with a reason and keeps its audio.
enum AppleSpeechEngine {
    /// What transcripts and version file names record as the model.
    static let modelID = "apple-speech"

    static var isAvailable: Bool {
        if #available(macOS 26.0, iOS 26.0, *) { return true }
        return false
    }

    /// `language` is Ata's setting: "auto" or a code like "pt". With "auto" and
    /// more than one plausible language, each stretch of speech is transcribed
    /// in its own language, as `LocalEngine.transcribeMixed` does for whisper.
    static func transcribe(audio: URL, speaker: String, language: String, plausible: [String],
                           progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw AppleSpeechError.unavailable }

        let supported = await AppleSpeechRecognizer.supportedLocaleIDs()
        let codes = language == "auto" ? plausible : [language]
        let locales: [(code: String, id: String)] = codes.compactMap { code in
            AppleSpeech.localeID(for: code, supported: supported).map { (code: code, id: $0) }
        }
        guard !locales.isEmpty else { throw AppleSpeechError.unsupported(codes.first ?? language) }

        // A model that isn't on this Mac yet is downloaded first: the first tenth of the bar.
        let count = Double(locales.count)
        for (i, locale) in locales.enumerated() {
            let base = 0.1 * Double(i) / count
            try await install(locale.id) { p in progress(base + 0.1 * p / count) }
        }
        progress(0.1)

        if locales.count == 1 {
            let results = try await AppleSpeechRecognizer.recognize(audio, localeID: locales[0].id) { p in
                progress(0.1 + 0.9 * p)
            }
            return AppleSpeech.segments(results, speaker: speaker)
        }

        // Someone who speaks more than one language may switch mid-call. The whole
        // track is transcribed once per language; then each stretch between pauses
        // keeps the transcript of the language it was spoken in. One pass per language
        // rather than one per piece: fewer runs, and each keeps its context across pauses.
        var heard: [String: [AppleSpeech.Result]] = [:]
        for (i, locale) in locales.enumerated() {
            let share = 0.9 / count
            let base = 0.1 + share * Double(i)
            heard[locale.code] = try await AppleSpeechRecognizer.recognize(audio, localeID: locale.id) { p in
                progress(base + share * p)
            }
        }
        let codesHeard = locales.map(\.code)
        let rate = Int(WavWriter.sampleRate)
        let pieces = try SpeechChunks.split(audio)
        let msPieces = pieces.map { ($0.lowerBound * 1000 / rate)..<($0.upperBound * 1000 / rate) }
        let detections = AppleSpeech.detections(heard, pieces: msPieces, plausible: codesHeard)
        // Where no piece is sure, the language of the whole track, else the user's first.
        let whole = AppleSpeech.detect(codesHeard.map { AppleSpeech.candidate($0, heard[$0] ?? []) },
                                       plausible: codesHeard)
        let runs = LanguageChoice.runs(detections, seconds: pieces.map { Double($0.count) / Double(rate) },
                                       plausible: codesHeard, fallback: whole?.code ?? codesHeard[0])
        progress(1)
        return AppleSpeech.segments(AppleSpeech.stitch(heard, pieces: msPieces, runs: runs), speaker: speaker)
    }

    /// The locale Ata would use for a language code, if Apple's recognizer has one.
    static func localeID(for code: String) async -> String? {
        guard #available(macOS 26.0, iOS 26.0, *) else { return nil }
        return AppleSpeech.localeID(for: code, supported: await AppleSpeechRecognizer.supportedLocaleIDs())
    }

    /// Whether the model for that locale is already on this device.
    static func isInstalled(_ localeID: String) async -> Bool {
        guard #available(macOS 26.0, iOS 26.0, *) else { return false }
        let installed = await AppleSpeechRecognizer.installedLocaleIDs()
        return installed.contains { AppleSpeech.sameLocale($0, localeID) }
    }

    /// Downloads the model for a locale through the system; returns at once when it is there.
    static func install(_ localeID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw AppleSpeechError.unavailable }
        do {
            try await AppleSpeechRecognizer.install(localeID, progress: progress)
        } catch {
            throw AppleSpeechError.download(error.localizedDescription)
        }
    }
}

enum AppleSpeechError: LocalizedError {
    case unavailable
    /// The language code Apple's recognizer has no locale for.
    case unsupported(String)
    case download(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return L("Apple's on-device speech recognition needs macOS 26. Choose whisper.cpp in Settings → Transcription.")
        case .unsupported(let code):
            #if os(iOS)
            return L("Apple's on-device speech doesn't support %@ yet.", AppleSpeech.languageName(code))
            #else
            return L("Apple's on-device speech doesn't support %@ yet — choose whisper.cpp in Settings → Transcription.",
                     AppleSpeech.languageName(code))
            #endif
        case .download(let message):
            return L("Apple's speech model could not be downloaded: %@", message)
        }
    }
}

/// The parts of the Apple engine that don't need the Speech framework at run
/// time: turning its results into segments and words, picking a locale, and
/// deciding the language of a stretch. Pure, so they are tested on any macOS.
enum AppleSpeech {
    /// A run of a result's text with one set of attributes: usually a word or a
    /// piece of one, sometimes a space or punctuation with no time of its own.
    struct Run: Equatable, Sendable {
        var text: String
        var start: Int? // ms
        var end: Int?   // ms
        /// 0–1, when the recognizer reported it.
        var confidence: Double? = nil
    }

    /// One finalized result: a stretch of speech up to a pause.
    struct Result: Equatable, Sendable {
        var start: Int // ms
        var end: Int   // ms
        var runs: [Run]
    }

    // MARK: Words and segments

    /// Opening marks start a word even when no space follows them.
    private static let openers: Set<Character> = ["“", "‘", "«", "(", "[", "{", "¿", "¡"]

    private static func attaches(_ part: String) -> Bool {
        part.allSatisfy { ($0.isPunctuation || $0.isSymbol) && !openers.contains($0) }
    }

    /// Runs into words. A run that follows a space starts a word; one that
    /// doesn't continues the word before it (a sub-word piece, or punctuation),
    /// and punctuation never stands alone. A run with no time takes the time
    /// of the word it joins, or the end of the word before it.
    static func words(_ runs: [Run], start: Int) -> [Segment.Word] {
        var out: [Segment.Word] = []
        var breakBefore = true
        for run in runs {
            if run.text.first?.isWhitespace == true { breakBefore = true }
            let parts = run.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let fallback = out.last?.end ?? start
            let times = spread(parts, from: run.start ?? fallback, to: run.end ?? run.start ?? fallback)
            for (i, part) in parts.enumerated() {
                let startsWord = (i > 0 || breakBefore) && !attaches(part)
                if startsWord || out.isEmpty {
                    out.append(.init(start: times[i].start, end: times[i].end, text: part))
                } else {
                    let last = out.removeLast()
                    let end = run.start == nil ? last.end : max(last.end, times[i].end)
                    out.append(.init(start: last.start, end: end, text: last.text + part))
                }
            }
            breakBefore = run.text.last?.isWhitespace == true
        }
        return out
    }

    /// A run holding several words shares its time between them by length.
    private static func spread(_ parts: [String], from start: Int, to end: Int) -> [(start: Int, end: Int)] {
        guard parts.count > 1 else { return parts.map { _ in (start: start, end: max(start, end)) } }
        let weights = parts.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        let span = Double(max(0, end - start))
        var at = Double(start)
        return weights.map { w -> (start: Int, end: Int) in
            let from = at
            at += span * w / total
            return (Int(from.rounded()), Int(at.rounded()))
        }
    }

    /// A segment shorter than this is not cut at a full stop: "Sr." is not a sentence.
    static let minSentenceMs = 1_500

    /// One segment per sentence of each result. Results run up to a pause and
    /// can hold a whole paragraph; sentences keep lines readable and give the
    /// speaker split shorter pieces to place.
    static func segments(_ results: [Result], speaker: String) -> [Segment] {
        results.flatMap { result -> [Segment] in
            sentences(words(result.runs, start: result.start)).compactMap { words -> Segment? in
                let text = words.map(\.text).joined(separator: " ")
                guard let first = words.first, let last = words.last, !Transcriber.isNoise(text) else { return nil }
                return Segment(speaker: speaker, start: first.start, end: last.end, text: text, words: words)
            }
        }
    }

    static func sentences(_ words: [Segment.Word]) -> [[Segment.Word]] {
        var out: [[Segment.Word]] = []
        var current: [Segment.Word] = []
        for w in words {
            current.append(w)
            let ending = w.text.reversed().first { !"\"'”’»)]".contains($0) }
            if let ending, ".?!…".contains(ending), let first = current.first, w.end - first.start >= minSentenceMs {
                out.append(current)
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: Locales

    /// The region each language falls back to when neither the user's
    /// languages nor their region pick one.
    static let defaultRegions = ["pt": "BR", "en": "US", "es": "ES", "fr": "FR", "de": "DE", "it": "IT"]

    /// The supported locale for one of Ata's language codes: the region from the
    /// user's own language list ("pt-PT"), else their region, else the
    /// language's usual one. Nil when the recognizer has no locale for it.
    static func localeID(for code: String, supported: [String],
                         preferred: [String] = Locale.preferredLanguages,
                         region: String? = Locale.current.region?.identifier) -> String? {
        let candidates = supported.filter { language(of: $0) == code }.sorted()
        guard !candidates.isEmpty else { return nil }
        var regions = preferred.filter { language(of: $0) == code }.compactMap(regionOf)
        if let region { regions.append(region) }
        if let usual = defaultRegions[code] { regions.append(usual) }
        for r in regions {
            if let match = candidates.first(where: { regionOf($0) == r }) { return match }
        }
        return candidates.first
    }

    static func sameLocale(_ a: String, _ b: String) -> Bool {
        language(of: a) == language(of: b) && regionOf(a) == regionOf(b)
    }

    private static func language(of id: String) -> String? {
        Locale(identifier: id).language.languageCode?.identifier
    }

    private static func regionOf(_ id: String) -> String? {
        Locale(identifier: id).region?.identifier
    }

    /// "Portuguese (Portugal)", in the app's language.
    static func languageName(_ idOrCode: String) -> String {
        let app = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return app.localizedString(forIdentifier: idOrCode) ?? idOrCode
    }

    // MARK: Which language a stretch was spoken in

    /// What one locale's recognizer heard in a stretch.
    struct Candidate: Equatable {
        var code: String
        var text: String
        var words: Int
        /// Mean log confidence of its runs, when the recognizer reported any.
        var logConfidence: Double?
    }

    static func candidate(_ code: String, _ results: [Result]) -> Candidate {
        let runs = results.flatMap(\.runs)
        let words = results.flatMap { Self.words($0.runs, start: $0.start) }
        let logs = runs.compactMap(\.confidence).map { log(min(1, max(0.01, $0))) }
        return Candidate(code: code, text: words.map(\.text).joined(separator: " "), words: words.count,
                         logConfidence: logs.isEmpty ? nil : logs.reduce(0, +) / Double(logs.count))
    }

    /// The language of a stretch, from each language's transcript of it.
    ///
    /// A recognizer set to the wrong language still writes something, but
    /// it is less sure of every word and what it writes reads less like its own
    /// language. Both count: the confidence as the likelihood of the words
    /// (mean log confidence times the same word count for every candidate, so
    /// writing fewer words is no advantage), and the text recognizer's
    /// probability that the text is in that language. Returns the winner with
    /// its share of the evidence, the shape `LanguageChoice.runs` takes.
    static func detect(_ candidates: [Candidate], plausible: [String],
                       hypotheses: (String, [String]) -> [String: Double] = AppleSpeech.languageHypotheses(_:among:))
        -> (code: String, p: Double)? {
        let heard = candidates.filter { plausible.contains($0.code) && $0.words > 0 }
        guard !heard.isEmpty else { return nil }
        let codes = heard.map(\.code)
        let n = Double(heard.map(\.words).max() ?? 0)
        let scores = heard.map { c -> Double in
            let text = hypotheses(c.text, codes)[c.code] ?? 0
            return (c.logConfidence ?? 0) * n + log(max(1e-6, text))
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        // Softmax, shifted by the best score so nothing underflows.
        let total = scores.reduce(0) { $0 + exp($1 - scores[best]) }
        return (heard[best].code, 1 / total)
    }

    /// NaturalLanguage's probability for each of `codes`, limited to them.
    static func languageHypotheses(_ text: String, among codes: [String]) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = codes.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        var out: [String: Double] = [:]
        for (language, p) in recognizer.languageHypotheses(withMaximum: codes.count) { out[language.rawValue] = p }
        return out
    }

    /// One detection per piece (ms ranges, back to back), from every language's transcript.
    static func detections(_ heard: [String: [Result]], pieces: [Range<Int>], plausible: [String],
                           hypotheses: (String, [String]) -> [String: Double] = AppleSpeech.languageHypotheses(_:among:))
        -> [(code: String, p: Double)?] {
        pieces.indices.map { i -> (code: String, p: Double)? in
            let range = pieceRange(pieces, i)
            return detect(plausible.map { candidate($0, clip(heard[$0] ?? [], to: range)) },
                          plausible: plausible, hypotheses: hypotheses)
        }
    }

    /// Each run of pieces in the transcript of its language, in time order.
    static func stitch(_ heard: [String: [Result]], pieces: [Range<Int>], runs: [LanguageChoice.Run]) -> [Result] {
        runs.flatMap { run -> [Result] in
            let first = pieceRange(pieces, run.pieces.lowerBound)
            let last = pieceRange(pieces, run.pieces.upperBound - 1)
            return clip(heard[run.language] ?? [], to: first.lowerBound..<last.upperBound)
        }
    }

    /// A piece's range, with the first and last left open so a word timed a
    /// little before the start or after the end of the audio still lands somewhere.
    private static func pieceRange(_ pieces: [Range<Int>], _ i: Int) -> Range<Int> {
        (i == 0 ? Int.min : pieces[i].lowerBound)..<(i == pieces.count - 1 ? Int.max : pieces[i].upperBound)
    }

    /// The parts of results said within `range`: a run belongs where its middle
    /// is, and a run without a time goes with the timed run before it (or after it).
    static func clip(_ results: [Result], to range: Range<Int>) -> [Result] {
        results.compactMap { r -> Result? in
            let middles = r.runs.map { run -> Int? in
                guard let s = run.start, let e = run.end else { return nil }
                return s + (e - s) / 2
            }
            var kept: [Run] = []
            for (i, run) in r.runs.enumerated() {
                let middle = middles[..<i].reversed().compactMap { $0 }.first
                    ?? middles[i...].compactMap { $0 }.first
                    ?? r.start + (r.end - r.start) / 2
                if range.contains(middles[i] ?? middle) { kept.append(run) }
            }
            guard kept.contains(where: { !$0.text.allSatisfy(\.isWhitespace) }) else { return nil }
            let starts = kept.compactMap(\.start), ends = kept.compactMap(\.end)
            return Result(start: starts.min() ?? max(r.start, range.lowerBound),
                          end: ends.max() ?? min(r.end, range.upperBound), runs: kept)
        }
    }
}

/// The only code that touches the Speech framework's new API, kept small so a
/// change in it is a change here and nowhere else.
@available(macOS 26.0, iOS 26.0, *)
enum AppleSpeechRecognizer {
    static func supportedLocaleIDs() async -> [String] {
        await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
    }

    static func installedLocaleIDs() async -> [String] {
        await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
    }

    private static func transcriber(_ localeID: String) -> SpeechTranscriber {
        // No volatile results: only final ones, each with a time for every word.
        SpeechTranscriber(locale: Locale(identifier: localeID), transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    static func install(_ localeID: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let module = transcriber(localeID)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let watch = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    static func recognize(_ audio: URL, localeID: String,
                          progress: @escaping @Sendable (Double) -> Void) async throws -> [AppleSpeech.Result] {
        let module = transcriber(localeID)
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: audio)
        let seconds = Double(file.length) / file.fileFormat.sampleRate

        let collect = Task { () throws -> [AppleSpeech.Result] in
            var out: [AppleSpeech.Result] = []
            for try await result in module.results {
                out.append(AppleSpeech.Result(start: ms(result.range.start), end: ms(result.range.end),
                                              runs: runs(result.text)))
                if seconds > 0 { progress(min(1, result.range.end.seconds / seconds)) }
            }
            return out
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collect.value
    }

    private static func runs(_ text: AttributedString) -> [AppleSpeech.Run] {
        text.runs.map { run -> AppleSpeech.Run in
            let range = run.audioTimeRange
            return AppleSpeech.Run(text: String(text[run.range].characters),
                                   start: range.map { ms($0.start) }, end: range.map { ms($0.end) },
                                   confidence: run.transcriptionConfidence)
        }
    }

    private static func ms(_ t: CMTime) -> Int {
        t.isNumeric ? Int((t.seconds * 1000).rounded()) : 0
    }
}

/// The state of Apple's speech model for each language Ata may transcribe, for Settings.
@MainActor
final class AppleSpeechModels: ObservableObject {
    enum State: Equatable {
        case checking, installed, missing, unsupported
        case downloading(Double)
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let code: String
        var localeID: String?
        var state: State
        var id: String { code }
        var name: String { AppleSpeech.languageName(localeID ?? code) }
    }

    @Published private(set) var rows: [Row] = []

    /// The languages "auto" can choose from, or the one the user set.
    func refresh(language: String) {
        guard AppleSpeechEngine.isAvailable else { rows = []; return }
        let codes = language == "auto" ? LanguageChoice.plausible : [language]
        rows = codes.map { Row(code: $0, localeID: nil, state: .checking) }
        Task {
            var found: [Row] = []
            for code in codes {
                guard let id = await AppleSpeechEngine.localeID(for: code) else {
                    found.append(Row(code: code, localeID: nil, state: .unsupported))
                    continue
                }
                let installed = await AppleSpeechEngine.isInstalled(id)
                found.append(Row(code: code, localeID: id, state: installed ? .installed : .missing))
            }
            // A download started meanwhile keeps showing its progress.
            self.rows = found.map { row -> Row in
                var row = row
                if case .downloading = self.state(of: row.code) { row.state = self.state(of: row.code) }
                return row
            }
        }
    }

    func download(_ code: String) {
        guard let id = rows.first(where: { $0.code == code })?.localeID else { return }
        set(code, .downloading(0))
        Task {
            do {
                try await AppleSpeechEngine.install(id) { p in
                    Task { @MainActor in
                        if case .downloading = self.state(of: code) { self.set(code, .downloading(p)) }
                    }
                }
                self.set(code, .installed)
            } catch {
                self.set(code, .failed(error.localizedDescription))
            }
        }
    }

    private func state(of code: String) -> State {
        rows.first { $0.code == code }?.state ?? .checking
    }

    private func set(_ code: String, _ state: State) {
        guard let i = rows.firstIndex(where: { $0.code == code }) else { return }
        rows[i].state = state
    }
}
