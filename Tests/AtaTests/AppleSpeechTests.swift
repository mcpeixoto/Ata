@testable import Ata
import XCTest

/// Apple's on-device engine, without the Speech framework: how its results
/// become segments and words, which locale a language gets, and how each
/// stretch of a bilingual call keeps its language. CI runs macOS 15, where
/// the recognizer itself does not exist, so everything here is the pure part.
final class AppleSpeechTests: XCTestCase {
    private typealias Run = AppleSpeech.Run
    private typealias Result = AppleSpeech.Result

    // MARK: Words

    func testSubWordRunsAndPunctuationJoinTheirWord() {
        let runs = [Run(text: "Lis", start: 0, end: 200), Run(text: "boa", start: 200, end: 500),
                    Run(text: ",", start: nil, end: nil), Run(text: " amanhã", start: 600, end: 1_000),
                    Run(text: " ,", start: nil, end: nil), Run(text: " ok", start: 1_100, end: 1_300),
                    Run(text: "?", start: 1_300, end: 1_350)]
        let words = AppleSpeech.words(runs, start: 0)
        XCTAssertEqual(words, [.init(start: 0, end: 500, text: "Lisboa,"),
                               .init(start: 600, end: 1_000, text: "amanhã,"),
                               .init(start: 1_100, end: 1_350, text: "ok?")])
    }

    func testSpacesOnTheirOwnSeparateWords() {
        let runs = [Run(text: "bom", start: 0, end: 300), Run(text: " ", start: nil, end: nil),
                    Run(text: "dia", start: 350, end: 700)]
        XCTAssertEqual(AppleSpeech.words(runs, start: 0).map(\.text), ["bom", "dia"])
    }

    func testARunOfSeveralWordsSharesItsTime() {
        let words = AppleSpeech.words([Run(text: " bom dia", start: 1_000, end: 1_800)], start: 1_000)
        XCTAssertEqual(words.map(\.text), ["bom", "dia"])
        XCTAssertEqual(words.first?.start, 1_000)
        XCTAssertEqual(words.last?.end, 1_800)
        XCTAssertEqual(words[0].end, words[1].start)
    }

    func testAnOpeningQuoteStartsAWord() {
        let runs = [Run(text: "disse", start: 0, end: 400), Run(text: " “", start: nil, end: nil),
                    Run(text: "olá", start: 500, end: 800), Run(text: "”", start: nil, end: nil)]
        XCTAssertEqual(AppleSpeech.words(runs, start: 0).map(\.text), ["disse", "“olá”"])
    }

    // MARK: Segments

    private func result(_ words: [(String, Int, Int)]) -> Result {
        Result(start: words.first?.1 ?? 0, end: words.last?.2 ?? 0,
               runs: words.enumerated().map { i, w in Run(text: (i == 0 ? "" : " ") + w.0, start: w.1, end: w.2) })
    }

    func testAResultIsCutIntoSentences() {
        let r = result([("Bom", 0, 300), ("dia", 300, 700), ("a", 700, 800), ("todos.", 800, 1_600),
                        ("Vamos", 2_000, 2_400), ("começar?", 2_400, 3_000)])
        let segments = AppleSpeech.segments([r], speaker: Speakers.me)
        XCTAssertEqual(segments.map(\.text), ["Bom dia a todos.", "Vamos começar?"])
        XCTAssertEqual(segments.map(\.start), [0, 2_000])
        XCTAssertEqual(segments.map(\.end), [1_600, 3_000])
        XCTAssertEqual(segments[1].words.map(\.text), ["Vamos", "começar?"])
        XCTAssertTrue(segments.allSatisfy { $0.speaker == Speakers.me })
    }

    func testAnAbbreviationIsNotASentence() {
        let r = result([("O", 0, 100), ("Sr.", 100, 500), ("Silva", 500, 900), ("chegou.", 900, 1_800)])
        XCTAssertEqual(AppleSpeech.segments([r], speaker: Speakers.others).map(\.text), ["O Sr. Silva chegou."])
    }

    func testEmptyResultsAndNoiseAreDropped() {
        let silent = Result(start: 0, end: 500, runs: [Run(text: " ", start: nil, end: nil)])
        let dots = result([("...", 600, 900)])
        XCTAssertTrue(AppleSpeech.segments([silent, dots], speaker: Speakers.me).isEmpty)
    }

    func testSegmentsFromAPieceMoveBackIntoTheTrack() {
        let s = AppleSpeech.segments([result([("Olá.", 100, 600)])], speaker: Speakers.me)[0].shifted(by: 30_000)
        XCTAssertEqual(s.start, 30_100)
        XCTAssertEqual(s.words, [.init(start: 30_100, end: 30_600, text: "Olá.")])
    }

    // MARK: Locales

    private let supported = ["de-DE", "en-AU", "en-GB", "en-US", "es-ES", "es-MX", "fr-FR", "pt-BR", "pt-PT"]

    func testPortugueseIsEuropeanInPortugalAndBrazilianElsewhere() {
        XCTAssertEqual(AppleSpeech.localeID(for: "pt", supported: supported, preferred: ["pt-PT", "en-GB"], region: "PT"),
                       "pt-PT")
        XCTAssertEqual(AppleSpeech.localeID(for: "pt", supported: supported, preferred: ["en-US"], region: "PT"), "pt-PT")
        XCTAssertEqual(AppleSpeech.localeID(for: "pt", supported: supported, preferred: ["en-US"], region: "US"), "pt-BR")
        XCTAssertEqual(AppleSpeech.localeID(for: "pt", supported: supported, preferred: ["pt-BR"], region: "PT"), "pt-BR",
                       "the user's own language list wins over the region")
        XCTAssertEqual(AppleSpeech.localeID(for: "pt", supported: supported.filter { $0 != "pt-PT" },
                                            preferred: ["pt-PT"], region: "PT"), "pt-BR",
                       "without European Portuguese, Brazilian is the closest there is")
    }

    func testEnglishFollowsTheUsersLanguagesThenRegion() {
        XCTAssertEqual(AppleSpeech.localeID(for: "en", supported: supported, preferred: ["pt-PT", "en-GB"], region: "PT"),
                       "en-GB")
        XCTAssertEqual(AppleSpeech.localeID(for: "en", supported: supported, preferred: ["pt-PT"], region: "PT"), "en-US")
        XCTAssertEqual(AppleSpeech.localeID(for: "en", supported: supported, preferred: ["pt-PT"], region: "GB"), "en-GB")
        XCTAssertEqual(AppleSpeech.localeID(for: "en", supported: supported, preferred: [], region: "AU"), "en-AU")
    }

    func testALanguageWithoutALocaleIsUnsupported() {
        XCTAssertNil(AppleSpeech.localeID(for: "cy", supported: supported, preferred: ["cy-GB"], region: "GB"))
        XCTAssertNil(AppleSpeech.localeID(for: "pt", supported: [], preferred: [], region: nil))
        XCTAssertEqual(AppleSpeech.localeID(for: "it", supported: ["it_IT"], preferred: [], region: nil), "it_IT")
        XCTAssertTrue(AppleSpeech.sameLocale("pt-PT", "pt_PT"))
        XCTAssertFalse(AppleSpeech.sameLocale("pt-PT", "pt-BR"))
    }

    func testTheUnsupportedErrorNamesTheLanguageAndTheWayOut() {
        let message = AppleSpeechError.unsupported("pt").errorDescription ?? ""
        XCTAssertTrue(message.lowercased().contains("portug"), message)
        XCTAssertTrue(message.contains("whisper.cpp"), message)
    }

    // MARK: Which language a stretch was spoken in

    /// NaturalLanguage's answer, fixed per text so the rule is tested, not the recognizer.
    private func fixed(_ table: [String: [String: Double]]) -> (String, [String]) -> [String: Double] {
        { text, _ in table[text] ?? [:] }
    }

    func testTheTranscriberThatIsSureOfItsWordsWins() {
        let pt = AppleSpeech.Candidate(code: "pt", text: "bom dia a todos vamos rever o orçamento", words: 8,
                                       logConfidence: log(0.9))
        let en = AppleSpeech.Candidate(code: "en", text: "bone the at those ramos revere", words: 6,
                                       logConfidence: log(0.4))
        let hypotheses = fixed([pt.text: ["pt": 0.97, "en": 0.03], en.text: ["en": 0.7, "pt": 0.3]])
        let d = AppleSpeech.detect([pt, en], plausible: ["pt", "en"], hypotheses: hypotheses)
        XCTAssertEqual(d?.code, "pt")
        XCTAssertGreaterThan(d?.p ?? 0, LanguageChoice.confidence)
    }

    func testWithoutConfidencesTheTextDecides() {
        let pt = AppleSpeech.Candidate(code: "pt", text: "obrigado", words: 1, logConfidence: nil)
        let en = AppleSpeech.Candidate(code: "en", text: "a bridge ado", words: 3, logConfidence: nil)
        let d = AppleSpeech.detect([pt, en], plausible: ["pt", "en"],
                                   hypotheses: fixed([pt.text: ["pt": 0.9], en.text: ["en": 0.3]]))
        XCTAssertEqual(d?.code, "pt")
        XCTAssertEqual(d?.p ?? 0, 0.75, accuracy: 1e-9)
    }

    func testNothingHeardIsNoDetection() {
        let empty = AppleSpeech.Candidate(code: "pt", text: "", words: 0, logConfidence: nil)
        let welsh = AppleSpeech.Candidate(code: "cy", text: "bore da", words: 2, logConfidence: log(0.99))
        XCTAssertNil(AppleSpeech.detect([empty, welsh], plausible: ["pt", "en"], hypotheses: fixed([:])))
    }

    func testNaturalLanguageTellsPortugueseFromEnglish() {
        let pt = AppleSpeech.languageHypotheses("Bom dia a todos. Hoje vamos rever o orçamento da campanha.",
                                                among: ["pt", "en"])
        let en = AppleSpeech.languageHypotheses("Thanks for joining from London. The budget was approved yesterday.",
                                                among: ["pt", "en"])
        XCTAssertGreaterThan(pt["pt"] ?? 0, 0.8)
        XCTAssertGreaterThan(en["en"] ?? 0, 0.8)
    }

    func testACandidateIsWhatItsTranscriptSaysWithinTheStretch() {
        let r = Result(start: 0, end: 1_000, runs: [Run(text: "bom", start: 0, end: 400, confidence: 0.5),
                                                    Run(text: " dia", start: 500, end: 1_000, confidence: 0.5)])
        let c = AppleSpeech.candidate("pt", [r])
        XCTAssertEqual(c.text, "bom dia")
        XCTAssertEqual(c.words, 2)
        XCTAssertEqual(c.logConfidence ?? 0, log(0.5), accuracy: 1e-9)
        XCTAssertNil(AppleSpeech.candidate("pt", [Result(start: 0, end: 10, runs: [Run(text: "x", start: 0, end: 10)])])
            .logConfidence)
    }

    // MARK: Portuguese, then English, then Portuguese, on one track

    /// Each language's transcript of the same 12 s: right where it was spoken in
    /// that language, sure of itself there and unsure elsewhere.
    private func heard() -> [String: [Result]] {
        func transcript(_ words: [(String, Int, Int, Double)]) -> [Result] {
            [Result(start: 0, end: 12_000, runs: words.enumerated().map { i, w in
                Run(text: (i == 0 ? "" : " ") + w.0, start: w.1, end: w.2, confidence: w.3)
            })]
        }
        return [
            "pt": transcript([("bom", 0, 1_500, 0.9), ("dia", 1_500, 3_500, 0.9),
                              ("fanks", 4_500, 6_000, 0.3), ("lôndon", 6_000, 7_500, 0.3),
                              ("até", 8_500, 10_000, 0.9), ("amanhã", 10_000, 11_500, 0.9)]),
            "en": transcript([("bone", 0, 1_500, 0.3), ("deer", 1_500, 3_500, 0.3),
                              ("thanks", 4_500, 6_000, 0.95), ("London", 6_000, 7_500, 0.95),
                              ("a tea", 8_500, 10_000, 0.3), ("I'm on", 10_000, 11_500, 0.3)]),
        ]
    }

    private let pieces = [0..<4_000, 4_000..<8_000, 8_000..<12_000]

    func testEachStretchKeepsTheTranscriptOfItsLanguage() {
        let transcripts = heard()
        let neutral: (String, [String]) -> [String: Double] = { _, codes in
            Dictionary(uniqueKeysWithValues: codes.map { ($0, 0.5) })
        }
        let detections = AppleSpeech.detections(transcripts, pieces: pieces, plausible: ["pt", "en"],
                                                hypotheses: neutral)
        XCTAssertEqual(detections.map { $0?.code }, ["pt", "en", "pt"])
        XCTAssertTrue(detections.allSatisfy { ($0?.p ?? 0) >= LanguageChoice.confidence })

        let runs = LanguageChoice.runs(detections, seconds: [4, 4, 4], plausible: ["pt", "en"], fallback: "pt")
        XCTAssertEqual(runs, [.init(pieces: 0..<1, language: "pt"), .init(pieces: 1..<2, language: "en"),
                              .init(pieces: 2..<3, language: "pt")])
        let segments = AppleSpeech.segments(AppleSpeech.stitch(transcripts, pieces: pieces, runs: runs),
                                            speaker: Speakers.me)
        XCTAssertEqual(segments.map(\.text), ["bom dia", "thanks London", "até amanhã"])
        XCTAssertEqual(segments.map(\.start), [0, 4_500, 8_500])
    }

    func testAWordJustOutsideTheAudioStillLands() {
        let late = [Result(start: 11_000, end: 12_400, runs: [Run(text: "fim", start: 11_900, end: 12_400)])]
        let stitched = AppleSpeech.stitch(["pt": late], pieces: pieces, runs: [.init(pieces: 0..<3, language: "pt")])
        XCTAssertEqual(stitched.first?.runs.map(\.text), ["fim"])
    }

    func testAnUntimedRunGoesWithTheWordBeforeIt() {
        let r = Result(start: 3_000, end: 5_000, runs: [Run(text: "dia", start: 3_000, end: 3_800),
                                                        Run(text: ".", start: nil, end: nil),
                                                        Run(text: " Thanks", start: 4_200, end: 5_000)])
        XCTAssertEqual(AppleSpeech.clip([r], to: 0..<4_000).first?.runs.map(\.text), ["dia", "."])
        let after = AppleSpeech.clip([r], to: 4_000..<8_000).first
        XCTAssertEqual(after?.runs.map(\.text), [" Thanks"])
        XCTAssertEqual(after?.start, 4_200)
    }

    // MARK: The engine choice

    func testAppleIsAFreeEngineThatNeedsNoWhisper() {
        XCTAssertEqual(Engine.apple.rawValue, "apple", "stored in settings and transcripts: must not change")
        XCTAssertEqual(Engine(rawValue: "apple"), .apple)
        XCTAssertTrue(Engine.apple.isLocal)
        XCTAssertFalse(Engine.apple.needsWhisper)
        XCTAssertTrue(Engine.local.needsWhisper)
        XCTAssertFalse(Engine.openAI.isLocal)

        let options = TranscribeOptions(engine: .apple, myName: "Alex", language: "auto", openAIModel: "whisper-1",
                                        localModel: "large-v3", summarize: false, summaryModel: "gpt-4o-mini")
        XCTAssertEqual(options.modelID, AppleSpeechEngine.modelID)
        XCTAssertEqual(options.transcriptionCost(seconds: 3_600), 0)
        var cloud = options
        cloud.engine = .openAI
        XCTAssertGreaterThan(cloud.transcriptionCost(seconds: 3_600), 0)

        let record = TranscriptionRecord(engine: "apple", model: AppleSpeechEngine.modelID, finishedAt: Date(),
                                         audioSeconds: 60, processingSeconds: 5, costUSD: 0, words: 100,
                                         mySpeechSeconds: 30, othersSpeechSeconds: 30, archivedAs: nil)
        XCTAssertTrue(record.isLocal, "counts as saved on this Mac in Insights")
    }

    func testAOneOffAppleRunKeepsTheWhisperModelSetting() {
        var m = Meeting(id: "t", startedAt: Date(), endedAt: nil, duration: nil, app: nil, status: .pending, error: nil)
        let before = TranscribeOptions.current()
        m.override = TranscribeOverride(engine: "apple", model: AppleSpeechEngine.modelID)
        let o = TranscribeOptions.current(for: m)
        XCTAssertEqual(o.engine, .apple)
        XCTAssertEqual(o.modelID, AppleSpeechEngine.modelID)
        XCTAssertEqual(o.localModel, before.localModel)
    }

    func testBeforeMacOS26TheEngineSaysWhyAndTouchesNothing() async throws {
        if #available(macOS 26.0, *) { throw XCTSkip("Apple's recognizer exists on this Mac") }
        let missing = URL(fileURLWithPath: "/nonexistent/mic.wav")
        do {
            _ = try await AppleSpeechEngine.transcribe(audio: missing, speaker: Speakers.me, language: "auto",
                                                       plausible: ["pt", "en"]) { _ in }
            XCTFail("transcribed without the recognizer")
        } catch AppleSpeechError.unavailable {
            XCTAssertFalse(AppleSpeechEngine.isAvailable)
        }
    }
}

/// The footer of a transcript says which engine wrote it. Renders a meeting, so on disk.
final class AppleSpeechTranscriptTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings + support folders, never the real ones
    }

    func testTheTranscriptSaysAppleTranscribedItOnThisMac() {
        let m = Meeting(id: "apple-footer", startedAt: Date(), endedAt: nil, duration: 60, app: nil,
                        status: .done, error: nil)
        let t = StoredTranscript(segments: [.init(start: 0, end: 1_000, text: "Olá.", speaker: Speakers.me)],
                                 coarse: false, summary: nil, engine: Engine.apple.rawValue,
                                 model: AppleSpeechEngine.modelID)
        let md = Transcriber.render(t, meeting: m, names: { $0 })
        XCTAssertTrue(md.contains("_Transcribed locally by Ata (Apple speech recognition)._"), md)
        XCTAssertFalse(md.contains("OpenAI"), md)
    }
}

/// The real recognizer on a bilingual single track. Opt-in, and only on macOS 26
/// with Portuguese among the Mac's languages, as the maintainer has:
///     ATA_AUDIO_TESTS=1 swift test --filter AppleSpeechAudioTests
final class AppleSpeechAudioTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATA_AUDIO_TESTS"] == "1",
                          "set ATA_AUDIO_TESTS=1 to run the audio integration tests")
        try XCTSkipUnless(AppleSpeechEngine.isAvailable, "Apple's speech recognition needs macOS 26")
        try XCTSkipUnless(LanguageChoice.plausible.contains("pt"),
                          "needs Portuguese in this Mac's languages, as the maintainer has")
        FilesTests.setUp()  // temp meetings + support folders, never the real ones
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: exe, code: Int(p.terminationStatus)) }
    }

    /// Lines spoken by `say`, one after another with a pause, into one 16 kHz WAV.
    private func conversation(_ lines: [(voice: String, text: String)], to wav: URL) throws {
        var pcm = Data()
        let pause = Data(count: Int(WavWriter.sampleRate) * 2 * 6 / 10)
        for (i, line) in lines.enumerated() {
            let aiff = wav.deletingLastPathComponent().appendingPathComponent("part-\(i).aiff")
            let part = aiff.deletingPathExtension().appendingPathExtension("wav")
            try run("/usr/bin/say", ["-v", line.voice, "-o", aiff.path, line.text])
            try AudioFiles.decodeToWAV(aiff, to: part)
            pcm.append(try Data(contentsOf: part).dropFirst(44))
            pcm.append(pause)
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: part)
        }
        var data = WavWriter.header(dataBytes: UInt32(pcm.count))
        data.append(pcm)
        try data.write(to: wav)
    }

    func testSwitchingLanguagesInTheSameVoiceKeepsEachLanguage() async throws {
        var m = try Meeting.new(app: "Teams")
        try conversation([
            ("Joana", "Bom dia a todos. Hoje vamos rever o orçamento da campanha e decidir as datas de lançamento."),
            ("Daniel", "Thanks for joining from London. The budget for the campaign was approved by finance yesterday."),
            ("Joana", "Perfeito. Então ficamos com quinta-feira para o lançamento e eu envio o resumo à equipa."),
        ], to: m.micURL)
        m.duration = WavWriter.duration(of: m.micURL)
        m.status = .transcribing

        var options = TranscribeOptions.current()
        options.engine = .apple
        options.language = "auto"
        options.myName = "Alex"
        options.summarize = false
        options.recogniseVoices = false
        let outcome = try await Transcriber.transcribe(m, options: options) { _ in }
        XCTAssertEqual(outcome.record.engine, "apple")
        XCTAssertEqual(outcome.record.costUSD, 0)

        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        if ProcessInfo.processInfo.environment["ATA_PRINT_TRANSCRIPT"] == "1" { print(md) }
        let text = md.lowercased()
        for word in ["orçamento", "lançamento"] { XCTAssertTrue(text.contains(word), "Portuguese kept: \(word)\n\(md)") }
        for word in ["london", "budget", "finance", "yesterday"] { XCTAssertTrue(text.contains(word), "English kept: \(word)\n\(md)") }
        XCTAssertFalse(text.contains("londres"), "English was not translated into Portuguese:\n\(md)")
        let stored = try XCTUnwrap(StoredTranscript.load(from: m.storedTranscriptURL))
        XCTAssertTrue(stored.segments.allSatisfy { !($0.words ?? []).isEmpty }, "every line has word times")
    }
}
