@testable import Ata
import XCTest

/// Live chunks with the real whisper-cli, then the final pass picking up only
/// the tail: words from before the cut and after it both reach the transcript.
///
/// Opt-in, like `EndToEndTests` (same model cache):
///     ATA_AUDIO_TESTS=1 swift test --filter LiveEndToEndTests
final class LiveEndToEndTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATA_AUDIO_TESTS"] == "1",
                          "set ATA_AUDIO_TESTS=1 to run the audio integration tests")
        try XCTSkipUnless(Paths.whisperCLI() != nil, "needs whisper-cli")
        FilesTests.setUp()
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: exe, code: Int(p.terminationStatus)) }
    }

    private func install(_ url: URL, as name: String, bytes: Int64) throws {
        let cache = EndToEndTests.cache
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
        let cached = cache.appendingPathComponent(name)
        if Paths.fileSize(cached) != bytes {
            try run("/usr/bin/curl", ["-sSfL", "-o", cached.path, url.absoluteString])
        }
        let target = Paths.modelsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: cached)
    }

    private func spoken(_ voice: String, _ text: String, in dir: URL) throws -> Data {
        let aiff = dir.appendingPathComponent("say-\(UUID().uuidString).aiff")
        let wav = aiff.deletingPathExtension().appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: wav)
        }
        try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
        try AudioFiles.decodeToWAV(aiff, to: wav)
        return try Data(contentsOf: wav).dropFirst(44)
    }

    private func silence(seconds: Double) -> Data {
        Data(count: Int(seconds * WavWriter.sampleRate) * 2)
    }

    /// Pads `pcm` with silence to `bytes`, so both tracks share one clock.
    private func write(_ pcm: Data, bytes: Int, to url: URL) throws {
        var body = pcm
        if body.count < bytes { body.append(Data(count: bytes - body.count)) }
        var data = WavWriter.header(dataBytes: UInt32(body.count))
        data.append(body)
        try data.write(to: url)
    }

    @MainActor
    func testWordsBeforeAndAfterTheLiveCutBothReachTheTranscript() async throws {
        let model = try XCTUnwrap(LocalModel.find("large-v3-turbo-q5_0"))
        try install(model.url, as: model.file, bytes: model.bytes)
        try install(Paths.vadModelURL, as: Paths.vadModel.lastPathComponent, bytes: 885_098)

        var m = try Meeting.new(app: "Zoom")
        // Early lines, a long pause where the live cut lands, then late lines only the final pass hears.
        var mic = try spoken("Joana", "Bom dia a todos. O lançamento está marcado para quinta-feira.", in: m.dir)
        mic.append(silence(seconds: 70))
        mic.append(try spoken("Joana", "Por fim, o orçamento ficou aprovado ontem à tarde.", in: m.dir))
        var system = silence(seconds: 20)
        system.append(try spoken("Daniel", "The marketing site is ready for Thursday.", in: m.dir))
        let bytes = max(mic.count, system.count)
        try write(mic, bytes: bytes, to: m.micURL)
        try write(system, bytes: bytes, to: m.systemURL)
        let micBytes = mic.count
        // The late Portuguese line starts after this many samples; live may only see up to here.
        let earlyFrames = (micBytes - (try spoken("Joana", "Por fim, o orçamento ficou aprovado ontem à tarde.",
                                                  in: m.dir)).count) / 2

        var options = TranscribeOptions.current()
        options.engine = .local
        options.localModel = model.id
        options.language = "auto"
        options.myName = "Alex"
        options.summarize = false
        options.cancelEcho = false
        options.recogniseVoices = false

        let live = LiveTranscriber(interval: 10_000, mayRun: { true }, whisperBusy: { _ in false })
        live.start(meeting: m, folder: m.dir, tracks: [
            LiveTrack(speaker: Speakers.me, url: m.micURL, frames: { earlyFrames }),
            LiveTrack(speaker: Speakers.others, url: m.systemURL, frames: { earlyFrames }),
        ], options: options)
        await live.tick()
        await live.stop()

        let state = try XCTUnwrap(LiveState.load(from: m.liveURL), "a live chunk was saved")
        XCTAssertGreaterThan(state.coveredUntilFrame, 0)
        XCTAssertLessThanOrEqual(state.coveredUntilFrame, earlyFrames)
        let liveText = state.segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(liveText.contains("quinta"), liveText)
        XCTAssertFalse(liveText.contains("orçamento"), "the late line is not live's: \(liveText)")

        m.duration = Double(bytes / 2) / WavWriter.sampleRate
        m.status = .transcribing
        _ = try await Transcriber.transcribe(m, options: options) { _ in }
        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8).lowercased()
        XCTAssertTrue(md.contains("quinta"), md)
        XCTAssertTrue(md.contains("orçamento") || md.contains("orcamento"), md)
        XCTAssertTrue(md.contains("marketing"), md)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.liveURL.path), "live.json goes once the transcript is saved")
    }
}
