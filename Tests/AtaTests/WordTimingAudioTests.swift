@testable import Ata
import XCTest

/// Real whisper-cli with VAD on: clicking a word has to play that word. Before
/// the fix every pause pulled the words after it earlier, and the last
/// sentence here came out twelve seconds early. Opt-in, like EndToEndTests:
///     ATA_AUDIO_TESTS=1 swift test --filter WordTimingAudioTests
final class WordTimingAudioTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATA_AUDIO_TESTS"] == "1",
                          "set ATA_AUDIO_TESTS=1 to run the audio integration tests")
        try XCTSkipUnless(Paths.whisperCLI() != nil, "needs whisper-cli")
        FilesTests.setUp()  // temp meetings + support folders, never the real ones
    }

    /// Links a model EndToEndTests already cached; skips if it hasn't run yet.
    private func link(_ name: String) throws {
        let cached = EndToEndTests.cache.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: cached.path), "run EndToEndTests once to cache \(name)")
        try FileManager.default.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
        let target = Paths.modelsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: cached)
    }

    /// The samples `say` speaks, with the leading silence trimmed so the first
    /// word starts at sample 0.
    private func spoken(_ text: String, in dir: URL) throws -> [Int16] {
        let aiff = dir.appendingPathComponent(UUID().uuidString + ".aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", "Samantha", "-o", aiff.path, text]
        try p.run()
        p.waitUntilExit()
        let reader = try PCM16Reader(aiff)
        var samples: [Int16] = []
        while let block = try reader.next() { samples += block }
        let first = samples.firstIndex { abs(Int($0)) > 300 } ?? 0
        return Array(samples[first...])
    }

    func testClickedWordsMatchTheAudioAcrossPauses() async throws {
        let model = try XCTUnwrap(LocalModel.find("large-v3-turbo-q5_0"))
        try link(model.file)
        try link(Paths.vadModel.lastPathComponent)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-word-timing-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sentences: [(at: Double, text: String, first: String)] = [
            (1.0, "The quarterly budget review starts on Monday morning.", "The"),
            (6.3, "Please send the revised contract before Friday.", "Please"),
            (12.7, "Our new office opens in Lisbon next spring.", "Our"),
            (19.2, "Marketing wants three more designers on the team.", "Marketing"),
            (25.9, "We should test the release on older machines first.", "We"),
            (31.4, "Coffee machines on the second floor are broken again.", "Coffee"),
        ]
        let rate = Int(WavWriter.sampleRate)
        var track = [Int16](repeating: 0, count: 38 * rate)
        for s in sentences {
            let voice = try spoken(s.text, in: dir)
            let start = Int(s.at * Double(rate))
            for (i, v) in voice.enumerated() where start + i < track.count { track[start + i] = v }
        }
        let wav = dir.appendingPathComponent("track.wav")
        var data = WavWriter.header(dataBytes: UInt32(track.count * 2))
        track.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: wav)

        let segments = try await LocalEngine.transcribe(audio: wav, speaker: "me", model: model,
                                                        language: "en") { _ in }
        let words = segments.flatMap(\.words)
        for s in sentences {
            let word = try XCTUnwrap(words.first { $0.text.lowercased().hasPrefix(s.first.lowercased()) },
                                     "\(s.first) in \(words.map(\.text))")
            XCTAssertEqual(Double(word.start) / 1000, s.at, accuracy: 0.6, "\(s.first) starts at \(s.at) s")
        }
    }
}
