@testable import Ata
import AVFoundation
import XCTest

/// The system track coming out at double speed.
///
/// A tap buffer whose format says stereo, while the buffer list holds one
/// channel, is accepted by `bufferListNoCopy` — both have a single buffer —
/// and the frame count comes out half. Those halves, laid end to end, are the
/// recording at double speed. The silence written afterwards makes the file
/// the length of the call, so the old length check never fired.
final class SystemAudioPaceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - The rate decision

    func testABufferThatFillsItsClockIsLeftAlone() {
        let dt = 512.0 / 48_000
        XCTAssertNil(DeliveryRate.corrected(frames: 512, claimedRate: 48_000, hostDelta: dt))
    }

    func testHalfTheFramesIsWrittenAtHalfTheRate() {
        // 256 frames claimed as 48 kHz, arriving once per 512 frames of clock.
        let dt = 512.0 / 48_000
        XCTAssertEqual(DeliveryRate.corrected(frames: 256, claimedRate: 48_000, hostDelta: dt), 24_000)
    }

    /// A 48 kHz claim over a 16 kHz hands-free clock. Three times fast.
    func testAThirdOfTheFramesIsTheBluetoothClock() {
        let dt = 480.0 / 16_000
        XCTAssertEqual(DeliveryRate.corrected(frames: 480, claimedRate: 48_000, hostDelta: dt), 16_000)
    }

    func testTwiceTheFramesIsWrittenAtTwiceTheRate() {
        let dt = 256.0 / 48_000
        XCTAssertEqual(DeliveryRate.corrected(frames: 512, claimedRate: 48_000, hostDelta: dt), 96_000)
    }

    /// The tap going quiet for two seconds is silence, not a wrong rate.
    func testADropoutIsNotARate() {
        XCTAssertNil(DeliveryRate.corrected(frames: 512, claimedRate: 48_000, hostDelta: 2))
        XCTAssertNil(DeliveryRate.corrected(frames: 512, claimedRate: 48_000, hostDelta: 0.001))
    }

    /// 0.7× is a glitch, not one of the clocks a device actually runs at.
    func testAnOddRatioIsNotGuessed() {
        XCTAssertNil(DeliveryRate.corrected(frames: 700, claimedRate: 48_000, hostDelta: 1_000.0 / 48_000))
    }

    // MARK: - What lands in the file

    /// The failure from the field: every callback carries half the frames the
    /// clock advanced, and the samples in it are the speech squeezed to fit.
    /// Written at the claimed rate, the file is the right length and the speech
    /// is at double speed. Written at the rate the samples came in, a 440 Hz
    /// tone is still 440 Hz and the file still fills the call.
    func testHalfFramesAtDoubleSpeedComeOutAtTheRightSpeed() throws {
        let claimed = 48_000.0
        let frames = 256
        let step = 512.0 / claimed // the clock advanced a full buffer
        let url = dir.appendingPathComponent("system.wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: claimed,
                                                 channels: 2, interleaved: true))
        var at = 0.0
        var phase = 0
        for _ in 0..<200 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData)
            let stride = buffer.stride
            for i in 0..<frames {
                // Generated at 24 kHz spacing: played at the claimed 48 kHz this is 880 Hz.
                let s = sin(2 * .pi * 440 * Float(phase + i) / 24_000) * 0.5
                data[0][i * stride] = s
                data[0][i * stride + 1] = s
            }
            phase += frames
            writer.append(buffer, hostSeconds: at)
            at += step
        }
        writer.close()

        let expected = 200 * step
        XCTAssertEqual(WavWriter.duration(of: url), expected, accuracy: expected * 0.05,
                       "the file has to stay as long as the call")
        XCTAssertEqual(try XCTUnwrap(writer.deliveryRatio), 0.5, accuracy: 0.05,
                       "the check sees the shortfall, which the padding used to hide")
        XCTAssertTrue(writer.correctedDelivery)
        let hz = try frequency(of: url)
        XCTAssertEqual(hz, 440, accuracy: 30, "played back at \(hz) Hz instead of 440")
    }

    /// The same cadence with a buffer that really does fill it is not rewritten.
    func testAFullBufferIsNotRewritten() throws {
        let rate = 48_000.0
        let frames = 512
        let step = Double(frames) / rate
        let url = dir.appendingPathComponent("system.wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                 channels: 2, interleaved: true))
        var at = 0.0
        var phase = 0
        for _ in 0..<120 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData)
            let stride = buffer.stride
            for i in 0..<frames {
                let s = sin(2 * .pi * 440 * Float(phase) / Float(rate)) * 0.5
                data[0][i * stride] = s
                data[0][i * stride + 1] = s
                phase += 1
            }
            writer.append(buffer, hostSeconds: at)
            at += step
        }
        writer.close()

        XCTAssertEqual(WavWriter.duration(of: url), at, accuracy: at * 0.02)
        XCTAssertEqual(try XCTUnwrap(writer.deliveryRatio), 1, accuracy: 0.02)
        XCTAssertFalse(writer.correctedDelivery)
        XCTAssertEqual(writer.inputFormats, ["48000 Hz × 2"])
        XCTAssertEqual(try frequency(of: url), 440, accuracy: 20)
    }

    /// Two seconds of nothing — the tap stalled — stays silence, and is not
    /// mistaken for a sample rate. The audio on either side keeps its pitch.
    func testATwoSecondDropoutStaysSilence() throws {
        let rate = 48_000.0
        let frames = 512
        let step = Double(frames) / rate
        let url = dir.appendingPathComponent("system.wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                 channels: 1, interleaved: true))
        var at = 0.0
        func burst() throws {
            for _ in 0..<40 {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                buffer.frameLength = AVAudioFrameCount(frames)
                let data = try XCTUnwrap(buffer.floatChannelData)
                for i in 0..<frames { data[0][i] = 0.2 }
                writer.append(buffer, hostSeconds: at)
                at += step
            }
        }
        try burst()
        at += 2
        try burst()
        writer.close()

        let audio = 80 * step
        XCTAssertEqual(writer.contentDuration, audio, accuracy: 0.05, "silence is not content")
        XCTAssertEqual(WavWriter.duration(of: url), audio + 2, accuracy: 0.1, "the gap stays in the file")
        XCTAssertFalse(writer.correctedDelivery)
    }

    // MARK: - The buffer list

    /// Stereo claim, one mono buffer. `bufferListNoCopy` refuses it, which used
    /// to drop the callback; reading the list's own channel count keeps every frame.
    func testAMonoBufferClaimedAsStereoKeepsEveryFrame() throws {
        let frames = 480
        let claimed = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                  channels: 2, interleaved: true))
        try withList(buffers: 1, channelsEach: 1, frames: frames) { list in
            XCTAssertNil(AVAudioPCMBuffer(pcmFormat: claimed, bufferListNoCopy: list, deallocator: nil),
                         "a channel count the format didn't ask for is refused, and the callback used to be dropped")

            let pcm = try XCTUnwrap(SystemAudioTap.pcmBuffer(from: list, claimed: claimed))
            XCTAssertEqual(pcm.frameLength, AVAudioFrameCount(frames))
            XCTAssertEqual(pcm.format.channelCount, 1)
            let data = try XCTUnwrap(pcm.floatChannelData)
            XCTAssertEqual(data[0][0], 0.25, accuracy: 1e-5)
            XCTAssertEqual(data[0][frames - 1], 0.25, accuracy: 1e-5)
        }
    }

    /// A list that really is what the format says is wrapped, not copied into a
    /// different shape.
    func testAMatchingStereoBufferKeepsItsFrameCount() throws {
        let frames = 512
        let claimed = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                  channels: 2, interleaved: true))
        try withList(buffers: 1, channelsEach: 2, frames: frames) { list in
            let pcm = try XCTUnwrap(SystemAudioTap.pcmBuffer(from: list, claimed: claimed))
            XCTAssertEqual(pcm.frameLength, AVAudioFrameCount(frames))
            XCTAssertEqual(pcm.format.channelCount, 2)
            XCTAssertTrue(pcm.format.isInterleaved)
        }
    }

    /// Planar stereo that the tap described as interleaved used to be dropped
    /// (`bufferListNoCopy` returns nil), which is a stretch of the track with
    /// nothing in it.
    func testAPlanarBufferTheFormatCallsInterleavedIsStillKept() throws {
        let frames = 256
        let claimed = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                  channels: 2, interleaved: true))
        try withList(buffers: 2, channelsEach: 1, frames: frames) { list in
            XCTAssertNil(AVAudioPCMBuffer(pcmFormat: claimed, bufferListNoCopy: list, deallocator: nil))
            let pcm = try XCTUnwrap(SystemAudioTap.pcmBuffer(from: list, claimed: claimed))
            XCTAssertEqual(pcm.frameLength, AVAudioFrameCount(frames))
            XCTAssertEqual(pcm.format.channelCount, 2)
            XCTAssertFalse(pcm.format.isInterleaved)
        }
    }

    // MARK: - Helpers

    private func frequency(of url: URL) throws -> Double {
        let data = try Data(contentsOf: url)
        let samples = data.dropFirst(44).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        guard samples.count > 2 else { return 0 }
        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0 && samples[i] >= 0)
            || (samples[i - 1] >= 0 && samples[i] < 0) { crossings += 1 }
        let seconds = Double(samples.count) / WavWriter.sampleRate
        return Double(crossings) / 2 / seconds
    }

    /// `frames` of 0.25 in every channel. The memory stays alive for `body`.
    private func withList(buffers: Int, channelsEach: UInt32, frames: Int,
                          _ body: (UnsafePointer<AudioBufferList>) throws -> Void) throws {
        let bytes = frames * Int(channelsEach) * MemoryLayout<Float>.size
        let listSize = MemoryLayout<AudioBufferList>.size + max(0, buffers - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(buffers)
        let abl = UnsafeMutableAudioBufferListPointer(list)
        var storage: [UnsafeMutableRawPointer] = []
        defer { storage.forEach { $0.deallocate() } }
        for i in 0..<buffers {
            let mem = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
            storage.append(mem)
            let samples = mem.assumingMemoryBound(to: Float.self)
            for n in 0..<(frames * Int(channelsEach)) { samples[n] = 0.25 }
            abl[i].mNumberChannels = channelsEach
            abl[i].mDataByteSize = UInt32(bytes)
            abl[i].mData = mem
        }
        try body(list)
    }
}

final class LanguagePiecesTests: XCTestCase {
    func testLeftoverPiecesAreRemovedAndTheRecordingIsNot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pieces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pieces = dir.appendingPathComponent("languages-39144C58", isDirectory: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        try Data([0]).write(to: pieces.appendingPathComponent("piece-0.wav"))
        try Data([1, 2]).write(to: dir.appendingPathComponent("system.m4a"))

        LanguagePieces.remove(in: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pieces.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.m4a").path))
    }
}
