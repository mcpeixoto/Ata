import AVFoundation
import XCTest
@testable import Ata

final class SystemAudioRepairTests: XCTestCase {
    private let rate = 16_000.0

    /// Six seconds of a 440 Hz tone, stored the way 2.11 stored the system
    /// track: samples at double speed, with a tenth of a second of digital
    /// silence after every tenth of a second of audio.
    private func corruptedTone() -> [Int16] {
        let fastCount = Int(rate * 3) // three seconds of samples, six seconds of the tone at 2×
        var fast: [Int16] = []
        fast.reserveCapacity(fastCount)
        for i in 0..<fastCount {
            let x = sin(2 * .pi * 880 * Double(i) / rate)
            fast.append(Int16(x * 8_000))
        }
        let chunk = Int(0.1 * rate)
        let pad = [Int16](repeating: 0, count: chunk)
        var packed: [Int16] = []
        var i = 0
        while i < fast.count {
            let end = min(i + chunk, fast.count)
            packed.append(contentsOf: fast[i..<end])
            packed.append(contentsOf: pad)
            i = end
        }
        return packed
    }

    func testPaddedDoubleSpeedAudioComesBackAtTheSpokenSpeed() {
        let broken = corruptedTone()
        XCTAssertEqual(SystemAudioRepair.longContentShare(broken, sampleRate: rate), 0, accuracy: 0.001)
        XCTAssertTrue(SystemAudioRepair.isCorrupt(broken, sampleRate: rate))
        let samples = try! XCTUnwrap(SystemAudioRepair.repaired(broken, sampleRate: rate))
        // Three seconds of tone, slowed to six, plus the three seconds of padding left in place.
        XCTAssertEqual(Double(samples.count) / rate, 9, accuracy: 0.2)
        let spoken = Array(samples.prefix(Int(0.2 * rate)))
        XCTAssertEqual(frequency(spoken), 440, accuracy: 15)
    }

    func testAnOrdinaryRecordingIsLeftAlone() {
        var tone: [Int16] = []
        let n = Int(rate * 8)
        for i in 0..<n {
            tone.append(Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8_000))
        }
        XCTAssertGreaterThan(SystemAudioRepair.longContentShare(tone, sampleRate: rate), 0.8)
        XCTAssertNil(SystemAudioRepair.repaired(tone, sampleRate: rate))
    }

    /// A clipped sample is Int16.min, and `abs` of it traps. This is the
    /// 3.0.0 launch crash (still in 3.0.1, whose rewrite of this scan kept
    /// `abs`): three healthy meetings each hold one, and the launch scan
    /// reaches it every time. The scan must read it as the loud sample it is.
    func testAClippedRecordingDoesNotCrash() {
        var tone: [Int16] = []
        let n = Int(rate * 8)
        for i in 0..<n {
            tone.append(Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8_000))
        }
        tone[n / 2] = .min
        XCTAssertGreaterThan(SystemAudioRepair.longContentShare(tone, sampleRate: rate), 0.8)
        XCTAssertFalse(SystemAudioRepair.isCorrupt(tone, sampleRate: rate))
        XCTAssertNil(SystemAudioRepair.repaired(tone, sampleRate: rate))
    }

    func testAStretchLongerThanASecondIsNotTheBug() {
        var samples = [Int16](repeating: 0, count: Int(rate * 30))
        for i in 0..<Int(rate * 2) { samples[i] = 1_000 }
        XCTAssertFalse(SystemAudioRepair.isCorrupt(samples, sampleRate: rate))
        XCTAssertNil(SystemAudioRepair.repaired(samples, sampleRate: rate))
    }

    /// Four percent of the sound in a long stretch is still the corruption.
    /// Six percent is a healthy recording that happens to have short replies,
    /// and it is left alone. The long stretch keeps its own speed.
    func testFivePercentIsTheLineAndALongStretchIsNotSlowed() {
        let corrupt = mixed(longSeconds: 1.2, shortSeconds: 30)
        XCTAssertLessThan(SystemAudioRepair.longContentShare(corrupt, sampleRate: rate), 0.05)
        let fixed = try! XCTUnwrap(SystemAudioRepair.repaired(corrupt, sampleRate: rate))
        XCTAssertEqual(frequency(Array(fixed.prefix(Int(1.2 * rate)))), 440, accuracy: 15,
                       "the long stretch was already at the right speed")
        let slowed = fixed.dropFirst(Int(1.3 * rate)).prefix(Int(0.2 * rate))
        XCTAssertEqual(frequency(Array(slowed)), 440, accuracy: 20,
                       "a short piece that was at double speed is slowed")

        let healthy = mixed(longSeconds: 2, shortSeconds: 30)
        XCTAssertGreaterThan(SystemAudioRepair.longContentShare(healthy, sampleRate: rate), 0.05)
        XCTAssertNil(SystemAudioRepair.repaired(healthy, sampleRate: rate))
    }

    /// `longSeconds` of 440 Hz, then `shortSeconds` of 880 Hz chopped into
    /// tenth-of-a-second pieces with a tenth of a second of silence after each.
    private func mixed(longSeconds: Double, shortSeconds: Double) -> [Int16] {
        var samples: [Int16] = []
        let longCount = Int(rate * longSeconds)
        for i in 0..<longCount {
            samples.append(Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8_000))
        }
        let piece = Int(0.1 * rate)
        samples.append(contentsOf: [Int16](repeating: 0, count: piece))
        let pieces = Int(shortSeconds / 0.1)
        for _ in 0..<pieces {
            for i in 0..<piece {
                samples.append(Int16(sin(2 * .pi * 880 * Double(i) / rate) * 8_000))
            }
            samples.append(contentsOf: [Int16](repeating: 0, count: piece))
        }
        return samples
    }

    func testTheOriginalFileIsKeptAndTheRepairedOnePlaysAtTheSpokenSpeed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("system.wav")
        try writeWAV(corruptedTone(), to: source)
        try Data("not the repaired track".utf8).write(to: dir.appendingPathComponent("meeting.mp3"))

        XCTAssertTrue(SystemAudioRepair.repairSystemTrack(in: dir))
        XCTAssertFalse(SystemAudioRepair.repairSystemTrack(in: dir), "a second pass finds the backup and stops")

        let backup = dir.appendingPathComponent("system.corrupted.wav")
        XCTAssertGreaterThan(Paths.fileSize(backup), 44)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meeting.mp3").path))
        let repaired = try read(dir.appendingPathComponent("system.wav"))
        XCTAssertEqual(frequency(Array(repaired.prefix(Int(0.2 * rate)))), 440, accuracy: 15)
    }

    /// A decoder can leave a spike of a few codes in an otherwise empty gap.
    /// Those spikes are not sound: the gap still splits the pieces, and the
    /// pieces still come back at the speed they were spoken.
    func testSpikesInTheGapsDoNotHideTheCorruption() {
        var broken = corruptedTone()
        for i in stride(from: 0, to: broken.count, by: 20) where broken[i] == 0 {
            broken[i] = 3
        }
        XCTAssertLessThan(SystemAudioRepair.longContentShare(broken, sampleRate: rate), 0.05)
        XCTAssertTrue(SystemAudioRepair.isCorrupt(broken, sampleRate: rate))
        let samples = try! XCTUnwrap(SystemAudioRepair.repaired(broken, sampleRate: rate))
        XCTAssertEqual(frequency(Array(samples.prefix(Int(0.2 * rate)))), 440, accuracy: 15)
    }

    /// A healthy file is not decoded again on the next launch.
    func testAHealthyTrackIsRemembered() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var tone: [Int16] = []
        let n = Int(rate * 8)
        for i in 0..<n {
            tone.append(Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8_000))
        }
        let source = dir.appendingPathComponent("system.wav")
        try writeWAV(tone, to: source)
        let before = try Data(contentsOf: source)

        XCTAssertFalse(SystemAudioRepair.repairSystemTrack(in: dir))
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try marker(in: dir), SystemAudioRepair.repairMarker)
        XCTAssertFalse(SystemAudioRepair.repairSystemTrack(in: dir))
    }

    /// The marker is what stops a second pass. While it is there, replacing
    /// the wav does not get repaired again.
    func testAMarkedFolderIsLeftAlone() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(corruptedTone(), to: dir.appendingPathComponent("system.wav"))
        XCTAssertTrue(SystemAudioRepair.repairSystemTrack(in: dir))

        let zeros = [Int16](repeating: 0, count: Int(rate * 6))
        try writeWAV(zeros, to: dir.appendingPathComponent("system.wav"))
        XCTAssertFalse(SystemAudioRepair.repairSystemTrack(in: dir))
        XCTAssertEqual(try read(dir.appendingPathComponent("system.wav")), zeros)
    }

    /// 3.0.1 stopped as soon as it saw a backup with the *current* extension.
    /// Repairing an m4a left `system.corrupted.m4a` and a wav, so the next
    /// launch found no `system.corrupted.wav`, treated the repaired wav as the
    /// original, and slowed it again. Deleting the marker and putting that
    /// second, wrong wav in place must rebuild from the kept original.
    func testARewrittenWavIsRebuiltFromTheKeptOriginal() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(corruptedTone(), to: dir.appendingPathComponent("system.wav"))
        XCTAssertTrue(SystemAudioRepair.repairSystemTrack(in: dir))
        let once = try read(dir.appendingPathComponent("system.wav"))
        XCTAssertEqual(frequency(Array(once.prefix(Int(0.2 * rate)))), 440, accuracy: 15)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("system.repair"))
        try writeWAV(SystemAudioRepair.stretchTwice(once), to: dir.appendingPathComponent("system.wav"))

        XCTAssertTrue(SystemAudioRepair.repairSystemTrack(in: dir))
        let restored = try read(dir.appendingPathComponent("system.wav"))
        XCTAssertEqual(restored.count, once.count)
        XCTAssertEqual(frequency(Array(restored.prefix(Int(0.2 * rate)))), 440, accuracy: 15)
        XCTAssertEqual(try marker(in: dir), SystemAudioRepair.repairMarker)
        XCTAssertGreaterThan(Paths.fileSize(dir.appendingPathComponent("system.corrupted.wav")), 44)
        XCTAssertFalse(SystemAudioRepair.repairSystemTrack(in: dir))
    }

    /// Same bug, the shape it had on disk: the original is `system.corrupted.m4a`
    /// and a later pass has also left `system.corrupted.wav` holding the
    /// already-slowed audio. The m4a is the original and wins. The container
    /// is lossless: a lossy encode smears the gaps and is no longer this bug.
    func testTheOriginalM4AWinsOverALaterWavBackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeM4A(corruptedTone(), to: dir.appendingPathComponent("system.corrupted.m4a"))
        // A long tone is not the corruption. Reading this backup by mistake
        // would leave the meeting at 220 Hz and report nothing to repair
        // once it had been copied into system.wav.
        var wrong: [Int16] = []
        let n = Int(rate * 8)
        for i in 0..<n {
            wrong.append(Int16(sin(2 * .pi * 220 * Double(i) / rate) * 8_000))
        }
        try writeWAV(wrong, to: dir.appendingPathComponent("system.corrupted.wav"))
        try writeWAV(wrong, to: dir.appendingPathComponent("system.wav"))

        XCTAssertTrue(SystemAudioRepair.repairSystemTrack(in: dir))
        let restored = try read(dir.appendingPathComponent("system.wav"))
        XCTAssertEqual(frequency(Array(restored.prefix(Int(0.2 * rate)))), 440, accuracy: 30)
        XCTAssertGreaterThan(Paths.fileSize(dir.appendingPathComponent("system.corrupted.m4a")), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.m4a").path))
    }

    /// An m4a backup that is not the corruption is the original. The wav
    /// backup beside it is a later copy, and repairing that copy would slow
    /// a track that was already repaired.
    func testAHealthyM4ABackupStopsTheLaterWavFromBeingSlowed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var tone: [Int16] = []
        let n = Int(rate * 8)
        for i in 0..<n {
            tone.append(Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8_000))
        }
        try writeM4A(tone, to: dir.appendingPathComponent("system.corrupted.m4a"))
        try writeWAV(corruptedTone(), to: dir.appendingPathComponent("system.corrupted.wav"))
        let wav = dir.appendingPathComponent("system.wav")
        try writeWAV(tone, to: wav)
        let before = try Data(contentsOf: wav)

        XCTAssertFalse(SystemAudioRepair.repairSystemTrack(in: dir))
        XCTAssertEqual(try Data(contentsOf: wav), before)
        XCTAssertEqual(try marker(in: dir), SystemAudioRepair.repairMarker)
    }

    /// An empty `system.corrupted.wav` is not an original. The repair still
    /// keeps the real file, and still slows only the short pieces.
    func testAnEmptyBackupPlaceholderIsReplacedByTheOriginal() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = corruptedTone()
        try writeWAV(broken, to: dir.appendingPathComponent("system.wav"))
        FileManager.default.createFile(atPath: dir.appendingPathComponent("system.corrupted.wav").path, contents: Data())

        XCTAssertTrue(SystemAudioRepair.repairSystemTrack(in: dir))
        let kept = try read(dir.appendingPathComponent("system.corrupted.wav"))
        XCTAssertEqual(kept, broken)
        let repaired = try read(dir.appendingPathComponent("system.wav"))
        XCTAssertEqual(frequency(Array(repaired.prefix(Int(0.2 * rate)))), 440, accuracy: 15)
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func marker(in dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent("system.repair"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writeM4A(_ samples: [Int16], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: out.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { throw CocoaError(.fileWriteUnknown) }
        for i in 0..<samples.count {
            dst[i] = Float(samples[i]) / 32_768
        }
        try out.write(from: buffer)
    }

    private func frequency(_ samples: [Int16]) -> Double {
        guard samples.count > 2 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0 && samples[i] >= 0)
            || (samples[i - 1] >= 0 && samples[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(samples.count) / rate)
    }

    private func writeWAV(_ samples: [Int16], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: WavWriter.header(dataBytes: UInt32(clamping: samples.count * 2)))
        try samples.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
    }

    private func read(_ url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}
