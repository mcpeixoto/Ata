@testable import Ata
import XCTest

/// A real local transcription through Ata's own pipeline: whisper-cli, a real
/// model, automatic language per track, the tuned flags, the Markdown and
/// the record.
///
/// Opt-in, because it needs whisper-cli (`brew install whisper-cpp`) and
/// downloads a 574 MB model once into ATA_TEST_MODEL_CACHE (default
/// /tmp/ata-test-models):
///     ATA_AUDIO_TESTS=1 swift test --filter EndToEndTests
final class EndToEndTests: XCTestCase {
    static let cache = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ATA_TEST_MODEL_CACHE"]
                           ?? "/tmp/ata-test-models", isDirectory: true)

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATA_AUDIO_TESTS"] == "1",
                          "set ATA_AUDIO_TESTS=1 to run the audio integration tests")
        try XCTSkipUnless(Paths.whisperCLI() != nil, "needs whisper-cli")
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

    /// Fetches a file into the cache once, then links it where Ata looks for it.
    private func install(_ url: URL, as name: String, bytes: Int64) throws {
        try FileManager.default.createDirectory(at: Self.cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
        let cached = Self.cache.appendingPathComponent(name)
        if Paths.fileSize(cached) != bytes {
            try run("/usr/bin/curl", ["-sSfL", "-o", cached.path, url.absoluteString])
        }
        XCTAssertEqual(Paths.fileSize(cached), bytes, "\(name) downloaded completely")
        let target = Paths.modelsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: cached)
    }

    private func speak(_ voice: String, _ text: String, to wav: URL) throws {
        let aiff = wav.deletingPathExtension().appendingPathExtension("aiff")
        try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
        try AudioFiles.decodeToWAV(aiff, to: wav)
        try? FileManager.default.removeItem(at: aiff)
    }

    func testAPortugueseAndEnglishMeetingIsTranscribedLocally() async throws {
        let model = try XCTUnwrap(LocalModel.find("large-v3-turbo-q5_0"))
        try install(model.url, as: model.file, bytes: model.bytes)
        try install(Paths.vadModelURL, as: Paths.vadModel.lastPathComponent, bytes: 885_098)
        XCTAssertTrue(model.isInstalled)

        var m = try Meeting.new(app: "Zoom")
        try speak("Joana", "Bom dia a todos. Hoje vamos falar sobre o lançamento da nova versão da aplicação, "
                  + "que está marcado para quinta-feira de manhã.", to: m.micURL)
        try speak("Daniel", "Thanks. The marketing site is ready, and the pricing page was approved by finance "
                  + "yesterday afternoon, so we are on track for Thursday.", to: m.systemURL)
        m.duration = 12
        m.status = .transcribing

        var options = TranscribeOptions.current()
        options.engine = .local
        options.localModel = model.id
        options.language = "auto"
        options.myName = "Alex"
        options.summarize = false

        let outcome = try await Transcriber.transcribe(m, options: options) { _ in }
        let original = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        if ProcessInfo.processInfo.environment["ATA_PRINT_TRANSCRIPT"] == "1" { print(original) }
        let md = original.lowercased()

        // Each track in its own language: Portuguese words from the mic, English from the system audio.
        XCTAssertTrue(md.contains("lançamento") || md.contains("lancamento"), md)
        XCTAssertTrue(md.contains("quinta"), md)
        XCTAssertTrue(md.contains("marketing"), md)
        XCTAssertTrue(md.contains("thursday"), md)
        XCTAssertTrue(md.contains("**[00:00] alex:**"), md)
        XCTAssertTrue(md.contains("others:**"), md)

        XCTAssertEqual(outcome.record.engine, "local")
        XCTAssertEqual(outcome.record.model, model.id)
        XCTAssertEqual(outcome.record.costUSD, 0)
        XCTAssertGreaterThan(outcome.record.words, 30)
        XCTAssertGreaterThan(outcome.record.mySpeechSeconds, 3)
        XCTAssertGreaterThan(outcome.record.othersSpeechSeconds, 3)
        XCTAssertNil(outcome.archivedPrevious)
    }

    /// Joins several spoken lines, each in its own voice, into one track with pauses.
    private func conversation(_ lines: [(voice: String, text: String)], to wav: URL) throws {
        var pcm = Data()
        let pause = Data(count: Int(WavWriter.sampleRate) * 2 * 6 / 10)
        for (i, line) in lines.enumerated() {
            let part = wav.deletingLastPathComponent().appendingPathComponent("part-\(i).wav")
            try speak(line.voice, line.text, to: part)
            pcm.append(try Data(contentsOf: part).dropFirst(44))
            pcm.append(pause)
            try? FileManager.default.removeItem(at: part)
        }
        var data = WavWriter.header(dataBytes: UInt32(pcm.count))
        data.append(pcm)
        try data.write(to: wav)
    }

    @MainActor
    func testVoicesAreLearnedNamedAndRecognisedInTheNextMeeting() async throws {
        try XCTSkipUnless(Diarization.isSupported, "voice recognition needs macOS 15")
        let model = try XCTUnwrap(LocalModel.find("large-v3-turbo-q5_0"))
        try install(model.url, as: model.file, bytes: model.bytes)
        try install(Paths.vadModelURL, as: Paths.vadModel.lastPathComponent, bytes: 885_098)
        PeopleModel.shared.forgetAll()

        var options = TranscribeOptions.current()
        options.engine = .local
        options.localModel = model.id
        options.language = "en"
        options.myName = "Alex"
        options.summarize = false
        options.recogniseVoices = true

        // Meeting one: Daniel and Samantha remote, Alex on the mic.
        var one = try Meeting.new(app: "Zoom")
        try speak("Fred", "Morning both. Let's keep this short, I only have fifteen minutes before my next call.", to: one.micURL)
        try conversation([
            ("Daniel", "Good morning everyone, thanks for joining. Let's go through the launch plan for next week, starting with the marketing site and the press list."),
            ("Samantha", "Sounds good. The marketing site is ready, but we're still waiting on the final screenshots from the design team before we can publish it."),
            ("Daniel", "Okay. Can we get those by Wednesday? I'd like a full day to review everything before we go live on Thursday morning."),
            ("Samantha", "I'll ask them today. If they slip, we can launch with the old screenshots and swap them in later that afternoon."),
        ], to: one.systemURL)
        one.duration = 50
        one.status = .done
        Library.save(one)  // as the queue does; renaming re-renders finished meetings only
        if let keep = ProcessInfo.processInfo.environment["ATA_KEEP_AUDIO_DIR"] {
            try? FileManager.default.copyItem(at: one.systemURL, to: URL(fileURLWithPath: keep).appendingPathComponent("one-system.wav"))
        }
        _ = try await Transcriber.transcribe(one, options: options) { _ in }

        var md = try String(contentsOf: one.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Voice 1:**") && md.contains("Voice 2:**"), md)
        XCTAssertFalse(md.contains("Others:**"), "every remote line got a speaker")
        let map = try XCTUnwrap(MeetingVoices.load(for: one))
        XCTAssertEqual(map.speakers.filter { $0.label != Speakers.me }.count, 2)

        // Name the voice that said "marketing site is ready" — Samantha.
        let stored = try XCTUnwrap(StoredTranscript.load(from: one.storedTranscriptURL))
        if ProcessInfo.processInfo.environment["ATA_PRINT_TRANSCRIPT"] == "1" {
            for s in stored.segments { print("SEG \(s.speaker) \(s.start)-\(s.end): \(s.text)") }
            for t in map.speakers { print("SPK \(t.label) \(t.seconds)s dim \(t.embedding.count)") }
        }
        let samanthaLabel = try XCTUnwrap(stored.segments.first { $0.text.lowercased().contains("design team") }?.speaker)
        let samanthaVoice = try XCTUnwrap(map.speakers.first { $0.label == samanthaLabel }?.voiceID)
        PeopleModel.shared.reload()
        let voice = try XCTUnwrap(PeopleModel.shared.voices.first { $0.id == samanthaVoice })
        XCTAssertNotNil(voice.sample, "a sample was cut so the user can hear who it is")
        PeopleModel.shared.rename(voice, to: "Samantha")

        md = try String(contentsOf: one.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Samantha:**"), "naming rewrote the existing transcript:\n\(md)")
        XCTAssertTrue(md.lowercased().contains("samantha:** sounds good"), "the turn starts at the right word:\n\(md)")
        let danielNumber = try XCTUnwrap(PeopleModel.shared.voices.first { !$0.isMe && $0.id != samanthaVoice }?.number)

        // Meeting two: the same people, different words.
        var two = try Meeting.new(app: "Zoom")
        try speak("Fred", "Quick sync today, I just want to confirm we are still on track for the launch.", to: two.micURL)
        try conversation([
            ("Samantha", "Quick update from my side: finance approved the pricing page this morning, so that part of the launch is fully done now."),
            ("Daniel", "Great news. The screenshots arrived last night as well, so we are on track for Thursday as originally planned."),
            ("Samantha", "Perfect. I'll schedule the announcement email for nine in the morning and let support know what to expect."),
            ("Daniel", "Thanks. Let's do a final check on Wednesday afternoon and then we can all relax a little before launch day."),
        ], to: two.systemURL)
        two.duration = 45
        let voicesBefore = PeopleModel.shared.voices.count
        _ = try await Transcriber.transcribe(two, options: options) { _ in }

        let md2 = try String(contentsOf: two.transcriptURL, encoding: .utf8)
        if ProcessInfo.processInfo.environment["ATA_PRINT_TRANSCRIPT"] == "1" { print(md, "\n\n", md2) }
        XCTAssertTrue(md2.lowercased().contains("samantha:** quick update"), "recognised by name in a new meeting:\n\(md2)")
        XCTAssertTrue(md2.contains("Voice \(danielNumber):** Great news"), "the same unnamed voice keeps its number:\n\(md2)")
        XCTAssertEqual(PeopleModel.shared.voices.count, voicesBefore, "no new voices: everyone was recognised")
        XCTAssertEqual(PeopleModel.shared.voices.first { $0.id == samanthaVoice }?.meetings, 2)
    }
}

extension EndToEndTests {
    /// The bug that started echo cancellation: without headphones the microphone
    /// hears the others through the speakers, and their words came out as yours.
    func testTheOthersHeardThroughTheSpeakersAreNotTranscribedAsYou() async throws {
        let model = try XCTUnwrap(LocalModel.find("large-v3-turbo-q5_0"))
        try install(model.url, as: model.file, bytes: model.bytes)
        try install(Paths.vadModelURL, as: Paths.vadModel.lastPathComponent, bytes: 885_098)

        var m = try Meeting.new(app: "Meet")
        try speak("Daniel", "Thanks everyone. The marketing site is ready, and the pricing page was approved by finance "
                  + "yesterday afternoon, so we are on track for the launch on Thursday.", to: m.systemURL)
        let alone = m.dir.appendingPathComponent("alex.wav")
        try speak("Fred", "Great, I will send the release notes tonight.", to: alone)

        // Alex speaks after Daniel; the laptop speakers play Daniel into the microphone,
        // soft-clipped, 70 ms late and with a few reflections, about as loud as Alex.
        func samples(_ url: URL) throws -> [Float] {
            try Data(contentsOf: url).dropFirst(44).withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
            }
        }
        let daniel = try samples(m.systemURL), alex = try samples(alone)
        let rate = Int(WavWriter.sampleRate)
        let n = daniel.count + alex.count + 2 * rate
        var system = [Float](repeating: 0, count: n), mic = system
        for (i, v) in daniel.enumerated() { system[i] = v }
        for (i, v) in alex.enumerated() { mic[daniel.count + rate + i] = v }
        let lag = rate * 7 / 100
        for (d, a) in [(0, 0.7), (180, 0.25), (530, -0.15), (1210, 0.1), (2300, 0.05)] {
            for i in 0..<(n - lag - d) { mic[i + lag + d] += Float(a) * tanh(2 * system[i]) / 2 }
        }
        func write(_ x: [Float], to url: URL) throws {
            var data = WavWriter.header(dataBytes: UInt32(x.count * 2))
            for v in x {
                let s = Int16(clamping: Int((max(-1, min(1, v)) * 32_767).rounded()))
                withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
            }
            try data.write(to: url)
        }
        try write(system, to: m.systemURL)
        try write(mic, to: m.micURL)
        try? FileManager.default.removeItem(at: alone)
        m.duration = Double(n) / Double(rate)
        m.status = .transcribing

        var options = TranscribeOptions.current()
        options.engine = .local
        options.localModel = model.id
        options.language = "en"
        options.myName = "Alex"
        options.summarize = false
        options.cancelEcho = true
        _ = try await Transcriber.transcribe(m, options: options) { _ in }

        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        if ProcessInfo.processInfo.environment["ATA_PRINT_TRANSCRIPT"] == "1" { print(md) }
        let mine = md.split(separator: "\n").filter { $0.contains("Alex:**") }.joined(separator: "\n").lowercased()
        let theirs = md.split(separator: "\n").filter { $0.contains("Others:**") }.joined(separator: "\n").lowercased()
        XCTAssertTrue(theirs.contains("marketing") && theirs.contains("thursday"), md)
        XCTAssertTrue(mine.contains("release notes"), md)
        for word in ["marketing", "pricing", "finance", "thursday"] {
            XCTAssertFalse(mine.contains(word), "\"\(word)\" was said by the others, not by you:\n\(md)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.dir.appendingPathComponent("mic.echo-cancelled.wav").path),
                       "the cleaned copy is temporary")
    }
}

extension EndToEndTests {
    /// Portuguese, then English, then Portuguese again, all on your microphone.
    /// Each stretch must come out in the language it was spoken, not translated.
    func testSwitchingLanguagesInTheSameVoiceKeepsEachLanguage() async throws {
        try XCTSkipUnless(LanguageChoice.plausible.contains("pt"),
                          "needs Portuguese in this Mac's languages, as the maintainer has")
        let model = try XCTUnwrap(LocalModel.find("large-v3-turbo-q5_0"))
        try install(model.url, as: model.file, bytes: model.bytes)
        try install(Paths.vadModelURL, as: Paths.vadModel.lastPathComponent, bytes: 885_098)

        var m = try Meeting.new(app: "Teams")
        try conversation([
            ("Joana", "Bom dia a todos. Hoje vamos rever o orçamento da campanha e decidir as datas de lançamento."),
            // Another voice, but the same microphone track, which is what matters here.
            ("Daniel", "Thanks for joining from London. The budget for the campaign was approved by finance yesterday."),
            ("Joana", "Perfeito. Então ficamos com quinta-feira para o lançamento e eu envio o resumo à equipa."),
        ], to: m.micURL)
        m.duration = WavWriter.duration(of: m.micURL)
        m.status = .transcribing

        var options = TranscribeOptions.current()
        options.engine = .local
        options.localModel = model.id
        options.language = "auto"
        options.myName = "Alex"
        options.summarize = false
        _ = try await Transcriber.transcribe(m, options: options) { _ in }

        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        if ProcessInfo.processInfo.environment["ATA_PRINT_TRANSCRIPT"] == "1" { print(md) }
        let text = md.lowercased()
        for word in ["orçamento", "lançamento", "quinta-feira"] { XCTAssertTrue(text.contains(word), "Portuguese kept: \(word)\n\(md)") }
        for word in ["london", "budget", "finance", "yesterday"] { XCTAssertTrue(text.contains(word), "English kept: \(word)\n\(md)") }
        XCTAssertFalse(text.contains("londres"), "English was not translated into Portuguese:\n\(md)")
    }
}
