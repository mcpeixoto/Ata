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
}
