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
        let repaired = SystemAudioRepair.samples(removingPads: corruptedTone(), sampleRate: rate)
        let samples = try! XCTUnwrap(repaired)
        XCTAssertEqual(Double(samples.count) / rate, 6, accuracy: 0.2, "the tone lasts as long as it was spoken")
        XCTAssertEqual(frequency(samples), 440, accuracy: 15)
        let zeros = samples.filter { abs($0) <= 1 }.count
        XCTAssertLessThan(Double(zeros) / Double(samples.count), 0.05, "the padding is gone")
    }

    func testAnOrdinaryRecordingIsLeftAlone() {
        var tone: [Int16] = []
        let n = Int(rate * 8)
        for i in 0..<n {
            tone.append(Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8_000))
        }
        XCTAssertNil(SystemAudioRepair.samples(removingPads: tone, sampleRate: rate))
    }

    func testOneLongSilenceIsNotTheBug() {
        var samples = [Int16](repeating: 0, count: Int(rate * 30))
        for i in 0..<Int(rate) { samples[i] = 1_000 }
        XCTAssertNil(SystemAudioRepair.samples(removingPads: samples, sampleRate: rate))
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
        XCTAssertEqual(frequency(repaired), 440, accuracy: 15)
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
