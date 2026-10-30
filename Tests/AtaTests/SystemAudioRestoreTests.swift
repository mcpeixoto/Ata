import AVFoundation
import XCTest
@testable import Ata

/// The repair passes after 3.0.4: putting back a healthy track an earlier
/// repair slowed, not re-repairing a compressed result, skipping files still in
/// iCloud, and the window of meetings the launch scan looks at.
final class SystemAudioRestoreTests: XCTestCase {
    private let rate = 16_000.0

    // MARK: Synthetic tracks

    /// A healthy system track that only carried notification blips: every
    /// sound short, every gap seconds long. 3.0.1–3.0.3 called this corrupt.
    private func blips(blipSeconds: Double = 0.3) -> [Int16] {
        var samples = [Int16](repeating: 0, count: Int(rate * 60))
        let blip = Int(rate * blipSeconds)
        var at = Int(rate)
        while at + blip < samples.count {
            for i in 0..<blip { samples[at + i] = Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8_000) }
            at += Int(rate * 6)
        }
        return samples
    }

    /// What 3.0.1–3.0.3 wrote from it: each blip stretched to twice its length.
    private func slowedBlips() -> [Int16] {
        let original = blips()
        XCTAssertFalse(SystemAudioRepair.isCorrupt(original, sampleRate: rate), "today's test calls it healthy")
        XCTAssertLessThan(SystemAudioRepair.longContentShare(original, sampleRate: rate), 0.05,
                          "the old, one-signal test called it corrupt")
        var out: [Int16] = []
        var i = 0
        while i < original.count {
            if original[i] == 0 {
                out.append(0)
                i += 1
            } else {
                var j = i
                while j < original.count, original[j] != 0 { j += 1 }
                out += SystemAudioRepair.stretchTwice(Array(original[i..<j]))
                i = j
            }
        }
        return out
    }

    /// The 2.11 corruption: double-speed tenth-of-a-second pieces with
    /// tenth-of-a-second pads.
    private func corrupted() -> [Int16] {
        var fast: [Int16] = []
        for i in 0..<Int(rate * 3) { fast.append(Int16(sin(2 * .pi * 880 * Double(i) / rate) * 8_000)) }
        let chunk = Int(0.1 * rate)
        var packed: [Int16] = []
        var i = 0
        while i < fast.count {
            let end = min(i + chunk, fast.count)
            packed += fast[i..<end]
            packed += [Int16](repeating: 0, count: chunk)
            i = end
        }
        return packed
    }

    // MARK: 1. A healthy original slowed by mistake is put back

    func testAHealthyOriginalSlowedByAnEarlierRepairIsPutBack() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = blips()
        try writeWAV(original, to: dir.appendingPathComponent("system.corrupted.wav"))
        try writeWAV(slowedBlips(), to: dir.appendingPathComponent("system.wav"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("system.repair"))
        try Data("drawn from the slowed track".utf8).write(to: dir.appendingPathComponent("waveform.bin"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .restored)
        XCTAssertEqual(try read(dir.appendingPathComponent("system.wav")), original)
        XCTAssertFalse(exists(dir, "system.corrupted.wav"), "the original is the system track again")
        XCTAssertFalse(exists(dir, "waveform.bin"))
        XCTAssertEqual(try marker(in: dir), "3")
        XCTAssertEqual(SystemAudioRepair.examine(dir), .unchanged, "judged once")
        XCTAssertEqual(try read(dir.appendingPathComponent("system.wav")), original)
    }

    /// The original was an m4a and the slowed track a wav: the m4a comes back
    /// under its own name and the slowed wav goes.
    func testAHealthyM4AOriginalComesBackAsTheM4A() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeM4A(blips(), to: dir.appendingPathComponent("system.corrupted.m4a"))
        try writeWAV(slowedBlips(), to: dir.appendingPathComponent("system.wav"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("system.repair"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .restored)
        XCTAssertTrue(exists(dir, "system.m4a"))
        XCTAssertFalse(exists(dir, "system.wav"))
        XCTAssertFalse(exists(dir, "system.corrupted.m4a"))
        XCTAssertEqual(SystemAudioRepair.frameCount(dir.appendingPathComponent("system.m4a")), blips().count)
    }

    /// The slowed wav was compressed after it was transcribed. The original
    /// wav replaces it, and the slowed m4a goes.
    func testAHealthyOriginalReplacesACompressedSlowedTrack() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = blips()
        try writeWAV(original, to: dir.appendingPathComponent("system.corrupted.wav"))
        try writeM4A(slowedBlips(), to: dir.appendingPathComponent("system.m4a"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .restored)
        XCTAssertEqual(try read(dir.appendingPathComponent("system.wav")), original)
        XCTAssertFalse(exists(dir, "system.m4a"))
    }

    /// A healthy original beside a track of the same length is not something
    /// a repair wrote: nothing moves.
    func testAHealthyOriginalBesideAnUnslowedTrackIsLeftAlone() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(blips(), to: dir.appendingPathComponent("system.corrupted.wav"))
        try writeWAV(blips(), to: dir.appendingPathComponent("system.wav"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .unchanged)
        XCTAssertTrue(exists(dir, "system.corrupted.wav"))
        XCTAssertTrue(exists(dir, "system.wav"))
    }

    /// The user had the audio deleted, and only the backup was left behind.
    /// It is not brought back.
    func testABackupAloneIsNotBroughtBack() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(blips(), to: dir.appendingPathComponent("system.corrupted.wav"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .unchanged)
        XCTAssertFalse(exists(dir, "system.wav"))
        XCTAssertTrue(exists(dir, "system.corrupted.wav"))
    }

    /// A real corruption that was repaired is still repaired: marker "2" is
    /// redone, finds the repaired wav already right, and changes nothing.
    func testARealRepairUnderTheOldMarkerStaysPut() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(corrupted(), to: dir.appendingPathComponent("system.wav"))
        XCTAssertEqual(SystemAudioRepair.examine(dir), .repaired)
        let fixed = try Data(contentsOf: dir.appendingPathComponent("system.wav"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("system.repair"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .unchanged)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("system.wav")), fixed)
        XCTAssertTrue(exists(dir, "system.corrupted.wav"))
    }

    // MARK: 7. A compressed repair is not repaired again

    func testACompressedRepairIsNotRepairedAgain() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = corrupted()
        try writeWAV(broken, to: dir.appendingPathComponent("system.corrupted.wav"))
        let fixed = try XCTUnwrap(SystemAudioRepair.repaired(broken, sampleRate: rate))
        try writeM4A(fixed, to: dir.appendingPathComponent("system.m4a"))
        let before = try Data(contentsOf: dir.appendingPathComponent("system.m4a"))
        try Data("2".utf8).write(to: dir.appendingPathComponent("system.repair"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .unchanged, "a second repair would queue a paid transcription")
        XCTAssertFalse(exists(dir, "system.wav"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("system.m4a")), before)
        XCTAssertEqual(try marker(in: dir), "3")
    }

    /// The compressed track is not the repair (it was slowed twice by 3.0.1):
    /// it is rebuilt from the original.
    func testACompressedTrackSlowedTwiceIsRebuilt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = corrupted()
        try writeWAV(broken, to: dir.appendingPathComponent("system.corrupted.wav"))
        let fixed = try XCTUnwrap(SystemAudioRepair.repaired(broken, sampleRate: rate))
        try writeM4A(SystemAudioRepair.stretchTwice(fixed), to: dir.appendingPathComponent("system.m4a"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .repaired)
        XCTAssertEqual(try read(dir.appendingPathComponent("system.wav")), fixed)
        XCTAssertFalse(exists(dir, "system.m4a"))
    }

    // MARK: 2. Files still in iCloud are not read

    func testATrackStillInICloudIsLeftForLater() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(corrupted(), to: dir.appendingPathComponent("system.wav"))
        // On iPhone an evicted file is a hidden `.name.icloud` stub.
        try Data().write(to: dir.appendingPathComponent(".system.corrupted.m4a.icloud"))

        XCTAssertEqual(SystemAudioRepair.examine(dir), .unchanged)
        XCTAssertFalse(exists(dir, "system.repair"), "not judged, so it is looked at again once it is here")
        XCTAssertFalse(exists(dir, "system.corrupted.wav"))
    }

    func testFilesAreComparedInPieces() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var big = [Int16](repeating: 7, count: 1_500_000) // 3 MB: several reads
        let a = dir.appendingPathComponent("a.wav"), b = dir.appendingPathComponent("b.wav")
        try writeWAV(big, to: a)
        try writeWAV(big, to: b)
        XCTAssertTrue(SystemAudioRepair.sameBytes(a, b))
        big[big.count - 1] = 8
        try writeWAV(big, to: b)
        XCTAssertFalse(SystemAudioRepair.sameBytes(a, b), "a difference in the last piece counts")
    }

    // MARK: 3. Which meetings the scan looks at

    func testOnlyMeetingsFromBeforeTheFixedWriterAreScanned() throws {
        let suite = "ata-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SystemAudioRepair.fixedWriterSince(defaults, now: firstLaunch), firstLaunch)
        XCTAssertEqual(SystemAudioRepair.fixedWriterSince(defaults, now: firstLaunch.addingTimeInterval(86_400)),
                       firstLaunch, "recorded once, then fixed")

        let old = Meeting(id: "old", startedAt: firstLaunch.addingTimeInterval(-3_600), status: .done)
        let new = Meeting(id: "new", startedAt: firstLaunch.addingTimeInterval(60), status: .done)
        XCTAssertTrue(SystemAudioRepair.mayHoldBrokenTrack(old, fixedSince: firstLaunch))
        XCTAssertFalse(SystemAudioRepair.mayHoldBrokenTrack(new, fixedSince: firstLaunch),
                       "a recording made by the fixed writer never enters the scan")

        var recording = old
        recording.status = .recording
        XCTAssertFalse(SystemAudioRepair.mayHoldBrokenTrack(recording, fixedSince: firstLaunch))
        var transcribing = old
        transcribing.status = .transcribing
        XCTAssertFalse(SystemAudioRepair.mayHoldBrokenTrack(transcribing, fixedSince: firstLaunch))
    }

    // MARK: What the meeting becomes

    func testARestoredMeetingIsNoLongerFlaggedAndIsTranscribedAgain() {
        var m = Meeting(id: "m", startedAt: Date(), status: .done)
        m.systemAudioCorrupt = true
        let restored = SystemAudioRepair.applying(.restored, to: m)
        XCTAssertNil(restored?.systemAudioCorrupt)
        XCTAssertEqual(restored?.status, .pending)

        m.systemAudioCorrupt = nil
        let repaired = SystemAudioRepair.applying(.repaired, to: m)
        XCTAssertEqual(repaired?.systemAudioCorrupt, true)
        XCTAssertEqual(repaired?.status, .pending)

        XCTAssertNil(SystemAudioRepair.applying(.unchanged, to: m))
    }

    // MARK: Helpers

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func exists(_ dir: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    private func marker(in dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("system.repair"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeWAV(_ samples: [Int16], to url: URL) throws {
        var data = WavWriter.header(dataBytes: UInt32(clamping: samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    private func read(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// Lossless, so the gaps survive: a lossy encode is not this bug.
    private func writeM4A(_ samples: [Int16], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: out.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { dst[i] = Float(samples[i]) / 32_768 }
        try out.write(from: buffer)
    }
}
