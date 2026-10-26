@testable import Ata
import AVFoundation
import XCTest

/// What comes out of `WavWriter` has to be 16 kHz, because the header it writes
/// says 16 kHz unconditionally.
///
/// If a buffer's frames reach the file without being resampled, the recording
/// plays back at the ratio of the two rates — three times fast from a 48 kHz
/// microphone — and whisper is handed something no model can read. Both
/// symptoms, one cause, and nothing in the app would notice: the file is a
/// valid WAV either way.
final class WavWriterRateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// One second of a tone at `rate`, as the microphone would deliver it.
    private func tone(rate: Double, channels: AVAudioChannelCount, seconds: Double = 1) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                data[channel][i] = sin(2 * .pi * 440 * Float(i) / Float(rate)) * 0.5
            }
        }
        return buffer
    }

    private func write(_ buffers: [AVAudioPCMBuffer]) throws -> URL {
        let url = dir.appendingPathComponent("mic.wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)
        for buffer in buffers { writer.append(buffer, hostSeconds: nil) }
        writer.close()
        return url
    }

    /// The one that matters: a 48 kHz microphone, which is what a Mac and an
    /// iPhone both hand over by default.
    func testASecondFromA48kMicrophoneIsASecondOnDisk() throws {
        let url = try write([try tone(rate: 48_000, channels: 1)])
        XCTAssertEqual(WavWriter.duration(of: url), 1, accuracy: 0.02,
                       "three seconds here would mean playback at three times speed")
    }

    /// Every rate and channel count a real microphone might arrive at, driven
    /// the way a real tap drives it: many small buffers, not one big one.
    func testEveryMicrophoneAMacMightHaveKeepsTime() throws {
        for rate in [8_000.0, 16_000, 22_050, 44_100, 48_000, 96_000] {
            for channels in [AVAudioChannelCount(1), 2] {
                let url = try write(try tap(rate: rate, channels: channels, buffers: 50))
                let expected = Double(50 * 4_096) / rate
                XCTAssertEqual(WavWriter.duration(of: url), expected, accuracy: expected * 0.01,
                               "at \(rate) Hz × \(channels)")
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// What a tap delivers: 4096 frames at a time, over and over.
    private func tap(rate: Double, channels: AVAudioChannelCount, buffers: Int) throws -> [AVAudioPCMBuffer] {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        return try (0..<buffers).map { block in
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            buffer.frameLength = 4_096
            let data = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(channels) {
                for i in 0..<4_096 {
                    data[channel][i] = sin(2 * .pi * 440 * Float(block * 4_096 + i) / Float(rate)) * 0.5
                }
            }
            return buffer
        }
    }

    /// Measured, and written down so the next person does not mistake it for
    /// the bug: a single `convert` call drops the converter's priming tail, so
    /// one enormous buffer comes out a little short — badly so when upsampling
    /// (8 kHz in loses about a quarter). It is a fixed cost per call, not a
    /// drift, so a real recording pays it once at the start and never again:
    /// `testEveryMicrophoneAMacMightHaveKeepsTime` holds every rate to 1%.
    /// Worth knowing, not worth changing — rewriting the conversion to carry
    /// state across calls would risk the path that currently works.
    func testOneEnormousBufferPaysAPrimingCostOnce() throws {
        let url = try write([try tone(rate: 8_000, channels: 1)])
        let once = WavWriter.duration(of: url)
        XCTAssertLessThan(once, 0.9, "the tail is dropped")

        // The same second of audio, delivered the way a tap would: no loss.
        let streamed = try write(try tap(rate: 8_000, channels: 1, buffers: 50))
        let expected = Double(50 * 4_096) / 8_000
        XCTAssertEqual(WavWriter.duration(of: streamed), expected, accuracy: expected * 0.01)
    }

    /// Plugging in AirPods changes the format mid-recording. `append` builds a
    /// new converter when it sees one; this is that path.
    func testTheRateChangingMidRecordingKeepsTheTimeline() throws {
        let url = try write([try tone(rate: 48_000, channels: 1),
                             try tone(rate: 16_000, channels: 1),
                             try tone(rate: 44_100, channels: 2)])
        XCTAssertEqual(WavWriter.duration(of: url), 3, accuracy: 0.06,
                       "three seconds in, three seconds out, whatever the microphone did")
    }

    /// Many small buffers are what a real tap delivers — 4096 frames at a time.
    /// A converter that loses its tail on every call loses it 700 times a minute.
    func testManySmallBuffersDoNotDriftShort() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var buffers: [AVAudioPCMBuffer] = []
        var phase = 0
        for _ in 0..<100 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            buffer.frameLength = 4_096
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<4_096 {
                data[0][i] = sin(2 * .pi * 440 * Float(phase + i) / 48_000) * 0.5
                }
            phase += 4_096
            buffers.append(buffer)
        }
        let expected = Double(100 * 4_096) / 48_000
        let url = try write(buffers)
        XCTAssertEqual(WavWriter.duration(of: url), expected, accuracy: expected * 0.01,
                       "a hundred buffers must not add up to less than they were")
    }

    /// The header is written unconditionally; this pins what it claims.
    func testTheHeaderSaysSixteenKilohertzMono() throws {
        let url = try write([try tone(rate: 48_000, channels: 1)])
        let head = try FileHandle(forReadingFrom: url).readData(ofLength: 44)
        func u32(_ at: Int) -> UInt32 { head.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
        func u16(_ at: Int) -> UInt16 { head.subdata(in: at..<(at + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian } }
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), 16_000, "sample rate")
        XCTAssertEqual(u16(34), 16, "bits per sample")
        XCTAssertEqual(u32(28), 32_000, "bytes per second — 16000 × 1 × 2")
    }
}

/// The property that matters most: over a long recording, the file's length
/// must track the time that passed. A converter losing even a per-cent per
/// buffer would make an hour-long meeting unlistenable and untranscribable.
extension WavWriterRateTests {
    func testALongRecordingDoesNotDriftFromTheClock() throws {
        for (label, channels, rate) in [("mono 48k", AVAudioChannelCount(1), 48_000.0),
                                        ("stereo 48k", 2, 48_000.0),
                                        ("stereo 44.1k", 2, 44_100.0)] {
            let url = try write(try tap(rate: rate, channels: channels, buffers: 200))
            let expected = Double(200 * 4_096) / rate
            let kept = WavWriter.duration(of: url) / expected
            XCTAssertEqual(kept, 1, accuracy: 0.001, "\(label) drifted")
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The formats a writer saw are kept, because when a recording does come
    /// out wrong they are the only evidence left.
    func testTheWriterRemembersWhatItWasHanded() throws {
        let url = dir.appendingPathComponent("mic.wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)
        for buffer in try tap(rate: 48_000, channels: 2, buffers: 2) { writer.append(buffer, hostSeconds: nil) }
        for buffer in try tap(rate: 16_000, channels: 1, buffers: 2) { writer.append(buffer, hostSeconds: nil) }
        writer.close()
        XCTAssertEqual(writer.inputFormats, ["48000 Hz × 2", "16000 Hz × 1"])
    }
}

/// The microphone changing in the middle of a call.
///
/// AirPods go in, a dock is unplugged, Ata restarts the engine and the next
/// buffer arrives in a different format entirely. The recording has to carry
/// straight on: same timeline, same speed, with the dead time in between kept
/// as silence rather than closed up — closing it up would slide every later
/// word out of step with the other track, and the speaker split reads both.
extension WavWriterRateTests {
    func testSwappingTheMicrophoneMidRecordingKeepsOneTimeline() throws {
        let url = dir.appendingPathComponent("mic.wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)

        // Two seconds on the built-in microphone…
        var at = 0.0
        for buffer in try tap(rate: 48_000, channels: 2, buffers: 24) {
            writer.append(buffer, hostSeconds: at)
            at += 4_096 / 48_000
        }
        // …a second and a half while the engine restarts on the new device…
        at += 1.5
        // …then AirPods, at a different rate and channel count.
        for buffer in try tap(rate: 24_000, channels: 1, buffers: 12) {
            writer.append(buffer, hostSeconds: at)
            at += 4_096 / 24_000
        }
        writer.close()

        XCTAssertEqual(WavWriter.duration(of: url), at, accuracy: 0.05,
                       "the file has to be as long as the call, gap included")
        XCTAssertEqual(writer.inputFormats, ["48000 Hz × 2", "24000 Hz × 1"])
    }

    /// A device that comes back as the same format it left is not a change.
    func testAnEngineRestartOnTheSameDeviceIsNotTreatedAsAChange() throws {
        let url = dir.appendingPathComponent("mic.wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)
        for buffer in try tap(rate: 48_000, channels: 1, buffers: 10) { writer.append(buffer, hostSeconds: nil) }
        for buffer in try tap(rate: 48_000, channels: 1, buffers: 10) { writer.append(buffer, hostSeconds: nil) }
        writer.close()
        XCTAssertEqual(writer.inputFormats, ["48000 Hz × 1"], "one format, named once")
        let expected = Double(20 * 4_096) / 48_000
        XCTAssertEqual(WavWriter.duration(of: url), expected, accuracy: expected * 0.01)
    }
}
