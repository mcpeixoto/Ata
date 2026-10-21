@testable import Ata
import XCTest

/// Runs the real diarization engine on synthetic two-person "meetings".
///
/// Opt-in, because it downloads FluidAudio's models (~21 MB) on first run:
///     ATA_AUDIO_TESTS=1 swift test --disable-keychain --filter DiarizationIntegrationTests
final class DiarizationIntegrationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATA_AUDIO_TESTS"] == "1",
                          "set ATA_AUDIO_TESTS=1 to run the audio integration tests")
        try XCTSkipUnless(Diarization.isSupported, "voice recognition needs macOS 15")
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-diarize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        super.tearDown()
    }

    /// Speaks each line with its voice and joins them, with a pause between, into a 16 kHz mono WAV.
    private func meeting(_ name: String, _ lines: [(voice: String, text: String)]) throws -> URL {
        var pcm = Data()
        let pause = Data(count: Int(WavWriter.sampleRate) * 2 * 6 / 10)
        for (i, line) in lines.enumerated() {
            let aiff = dir.appendingPathComponent("\(name)-\(i).aiff")
            let wav = dir.appendingPathComponent("\(name)-\(i).wav")
            try run("/usr/bin/say", ["-v", line.voice, "-o", aiff.path, line.text])
            // Ata's own decoder writes exactly the 44-byte header + 16 kHz mono PCM it records.
            try AudioFiles.decodeToWAV(aiff, to: wav)
            pcm.append(try Data(contentsOf: wav).dropFirst(44))
            pcm.append(pause)
        }
        let out = dir.appendingPathComponent("\(name).wav")
        var data = WavWriter.header(dataBytes: UInt32(pcm.count))
        data.append(pcm)
        try data.write(to: out)
        return out
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: exe, code: Int(p.terminationStatus)) }
    }

    func testTheSameVoicesAreRecognisedInASecondMeeting() async throws {
        let a = try meeting("a", [
            ("Daniel", "Good morning everyone, thanks for joining. Let's go through the launch plan for next week, starting with the marketing site and the press list."),
            ("Samantha", "Sounds good. The marketing site is ready, but we're still waiting on the final screenshots from the design team before we can publish it."),
            ("Daniel", "Okay. Can we get those by Wednesday? I'd like a full day to review everything before we go live on Thursday morning."),
            ("Samantha", "I'll ask them today. If they slip, we can launch with the old screenshots and swap them in later that afternoon."),
            ("Daniel", "Fine, that works. Next item is the pricing page, which still shows last year's plans and needs to be updated before launch."),
            ("Samantha", "I updated it yesterday. It just needs a last check from finance, and then it can go out with everything else."),
        ])
        let b = try meeting("b", [
            ("Samantha", "Quick update from my side: finance approved the pricing page this morning, so that part of the launch is fully done now."),
            ("Daniel", "Great news. The screenshots arrived last night as well, so we are on track for Thursday as originally planned."),
            ("Samantha", "Perfect. I'll schedule the announcement email for nine in the morning and let support know what to expect."),
            ("Daniel", "Thanks. Let's do a final check on Wednesday afternoon and then we can all relax a little before launch day."),
        ])

        let diarizer = FluidDiarizer()
        let library = VoiceLibrary(file: dir.appendingPathComponent("voices.json"))

        func speakers(_ wav: URL, _ id: String) async throws -> [MeetingSpeaker] {
            let found = try await diarizer.diarize(wav)
            XCTAssertEqual(found.embeddings.count, 2, "\(id): two people talking")
            let speakers = found.embeddings.map { MeetingSpeaker(label: $0.key, embedding: $0.value, seconds: 20, voiceID: nil) }
            return library.assign(speakers, meetingID: id)
        }

        let first = try await speakers(a, "a")
        XCTAssertEqual(library.voices.count, 2)
        let second = try await speakers(b, "b")
        XCTAssertEqual(library.voices.count, 2, "no new voices: both were recognised")
        XCTAssertEqual(Set(second.compactMap(\.voiceID)), Set(first.compactMap(\.voiceID)))
        XCTAssertTrue(library.voices.allSatisfy { $0.meetingIDs == ["a", "b"] })
    }
}
