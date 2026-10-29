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
