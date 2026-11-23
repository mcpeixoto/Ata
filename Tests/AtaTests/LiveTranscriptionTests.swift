import AVFoundation
@testable import Ata
import XCTest

/// Live chunks are an accelerator. These tests pin the cut, the coverage, and
/// the join with the final pass — none of them run whisper.
@MainActor
final class LiveTranscriptionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    private let rate = Int(WavWriter.sampleRate)

    // MARK: Cut

    func testCutLandsInTheLastPauseAndNotPastTheAudio() {
        // 50 loud, 20 quiet, 30 loud, 25 quiet. The last pause is the trailing one.
        let tail = tone(50, 8000) + tone(20, 0) + tone(30, 8000) + tone(25, 0)
        let written = 80 * rate
        let cut = LiveCut.choose(written: written, coveredUntil: 0, tail: tail)
        let frames = tail.count / SpeechChunks.frame
        let trailing = 25
        let pauseFrame = frames - trailing / 2
        let expected = written - tail.count + pauseFrame * SpeechChunks.frame
        XCTAssertEqual(cut, expected)
        XCTAssertLessThanOrEqual(cut!, written)
        XCTAssertGreaterThanOrEqual(cut!, written - tail.count)
    }

    func testCutUsesTheQuietestFrameWhenNothingPauses() {
        var tail = tone(80, 8000)
        let quietAt = 40
        let frame = SpeechChunks.frame
        for i in (quietAt * frame)..<((quietAt + 1) * frame) { tail[i] = 200 }
        let written = 80 * rate
        let cut = LiveCut.choose(written: written, coveredUntil: 0, tail: tail)
        XCTAssertEqual(cut, written - tail.count + quietAt * frame)
        XCTAssertLessThanOrEqual(cut!, written)
    }

    func testCutSkipsUnderAMinuteOfNewAudio() {
        let tail = tone(30, 1000)
        XCTAssertNil(LiveCut.choose(written: 60 * rate - 1, coveredUntil: 0, tail: tail))
        XCTAssertNil(LiveCut.choose(written: 100 * rate, coveredUntil: 50 * rate, tail: tail))
        let cut = LiveCut.choose(written: 60 * rate, coveredUntil: 0, tail: tail)
        XCTAssertNotNil(cut)
        XCTAssertLessThanOrEqual(cut!, 60 * rate)
    }

    func testCutNeverReadsPastTheSamplesThatExist() throws {
        let written = 80 * rate
        let frame = SpeechChunks.frame
        // The buffer is longer than the file. The extra samples sit in front and
        // are silence; the file itself opens loud. A cut taken from the extra
        // samples would land on their pause, not on the file's first quiet frame.
        var tail = [Int16](repeating: 0, count: written + 40 * frame)
        let realStart = tail.count - written
        for i in realStart..<(realStart + 40 * frame) { tail[i] = 8000 }
        let cut = try XCTUnwrap(LiveCut.choose(written: written, coveredUntil: 0, tail: tail))
        XCTAssertEqual(cut, 40 * frame)
        XCTAssertLessThanOrEqual(cut, written)
    }

    // MARK: Chunks

    func testChunksAbutWithoutGapsOrOverlap() async throws {
        let folder = FilesTests.root.appendingPathComponent("chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("mic.wav")
        let before = try writeTone(seconds: 200, to: url)
        let frames = Frames(80 * rate)
        let lengths = LockedValue<[Int]>([])
        let live = LiveTranscriber(
            interval: 10_000,
            transcribe: { audio, speaker, _, _ in
                lengths.withLock { $0.append(LiveAudio.samples(in: audio)) }
                return [Segment(speaker: speaker, start: 0, end: 100, text: "hi")]
            },
            mayRun: { true },
            whisperBusy: { _ in false })
        let meeting = Meeting(id: "chunks", startedAt: Date(), endedAt: nil, duration: nil,
                              app: nil, status: .recording, error: nil)
        live.start(meeting: meeting, folder: folder, tracks: [
            LiveTrack(speaker: Speakers.me, url: url, frames: { frames.value }),
        ], options: TranscribeOptions(engine: .local, myName: "Me", language: "en",
                                     localModel: "large-v3", cancelEcho: false, summarize: false))

        await live.tick()
        let first = live.coveredUntilFrame
        XCTAssertGreaterThan(first, 0)
        XCTAssertLessThan(first, frames.value)
        XCTAssertEqual(lengths.withLock { $0 }, [first])

        frames.value = 160 * rate
        await live.tick()
        let second = live.coveredUntilFrame
        XCTAssertEqual(lengths.withLock { $0 }, [first, second - first])
        XCTAssertGreaterThan(second, first)
        XCTAssertLessThanOrEqual(second, frames.value)
        XCTAssertEqual(live.segments.map(\.start), [0, first * 1000 / rate])

        let saved = LiveState.load(from: folder.appendingPathComponent("live.json"))
        XCTAssertEqual(saved?.coveredUntilFrame, second)
        XCTAssertEqual(saved?.segments.map(\.start), live.segments.map(\.start))
        XCTAssertEqual(try Data(contentsOf: url), before)
        let kids = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertFalse(kids.contains { $0.lastPathComponent.hasPrefix("live-") })
        await live.stop()
    }

    func testAFailedChunkDoesNotAdvanceCoverage() async throws {
        let folder = FilesTests.root.appendingPathComponent("fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("mic.wav")
        _ = try writeTone(seconds: 90, to: url)
        let live = LiveTranscriber(
            interval: 10_000,
            transcribe: { _, _, _, _ in throw TranscriberError.failed("no") },
            mayRun: { true },
            whisperBusy: { _ in false })
        let meeting = Meeting(id: "fail", startedAt: Date(), endedAt: nil, duration: nil,
                              app: nil, status: .recording, error: nil)
        live.start(meeting: meeting, folder: folder, tracks: [
            LiveTrack(speaker: Speakers.me, url: url, frames: { 80 * Int(WavWriter.sampleRate) }),
        ], options: TranscribeOptions(engine: .local, myName: "Me", language: "en",
                                     localModel: "large-v3", cancelEcho: false, summarize: false))
        await live.tick()
        XCTAssertEqual(live.coveredUntilFrame, 0)
        XCTAssertNil(LiveState.load(from: folder.appendingPathComponent("live.json")))
        await live.stop()
    }

    func testLowPowerSkipsTheTick() async throws {
        let folder = FilesTests.root.appendingPathComponent("power-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("mic.wav")
        let meeting = Meeting(id: "power", startedAt: Date(), endedAt: nil, duration: nil,
                              app: nil, status: .recording, error: nil)
        let live = LiveTranscriber(interval: 10_000, mayRun: { false }, whisperBusy: { _ in true })
        live.start(meeting: meeting, folder: folder, tracks: [
            LiveTrack(speaker: Speakers.me, url: url, frames: { 80 * Int(WavWriter.sampleRate) }),
        ], options: TranscribeOptions(engine: .local, myName: "Me", language: "en",
                                     localModel: "large-v3", cancelEcho: false, summarize: false))
        await live.tick()
        XCTAssertEqual(live.coveredUntilFrame, 0)
        await live.stop()
    }

    // MARK: State and the final-pass join

    func testLiveStateRoundTripAndWhatMakesItUsable() throws {
        let segment = Segment(speaker: "me", start: 0, end: 1_000, text: "hi",
                              words: [Segment.Word(start: 10, end: 400, text: "hi")])
        let state = LiveState(version: 1, engine: "local", model: "large-v3", language: "en",
                              coveredUntilFrame: 16_000, languages: ["me": "en"], segments: [segment])
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(LiveState.self, from: data), state)

        let url = FilesTests.root.appendingPathComponent("live-\(UUID().uuidString).json")
        try state.save(to: url)
        XCTAssertEqual(LiveState.load(from: url), state)

        let fitting = TranscribeOptions(engine: .local, myName: "Me", language: "en",
                                        localModel: "large-v3", summarize: false)
        XCTAssertTrue(state.matches(options: fitting, trackFrames: [16_000, 32_000]))
        XCTAssertFalse(state.matches(options: fitting, trackFrames: [15_999]))

        var otherEngine = fitting
        otherEngine.engine = .apple
        XCTAssertFalse(state.matches(options: otherEngine, trackFrames: [32_000]))
        var otherModel = fitting
        otherModel.localModel = "tiny"
        XCTAssertFalse(state.matches(options: otherModel, trackFrames: [32_000]))
        var otherLanguage = fitting
        otherLanguage.language = "pt"
        XCTAssertFalse(state.matches(options: otherLanguage, trackFrames: [32_000]))
        var fullRun = fitting
        fullRun.useLiveState = false
        XCTAssertFalse(state.matches(options: fullRun, trackFrames: [32_000]))
    }

    func testMergeMatchesOnePass() {
        let stored = [
            Segment(speaker: "me", start: 0, end: 1_000, text: "hello",
                    words: [Segment.Word(start: 100, end: 400, text: "hello")]),
        ]
        let tail = [
            Segment(speaker: "others", start: 100, end: 900, text: "there",
                    words: [Segment.Word(start: 100, end: 500, text: "there")]),
        ]
        let merged = Transcriber.mergeLive(stored: stored, tail: tail, tailOffsetMs: 5_000)
        let singlePass = [
            stored[0],
            Segment(speaker: "others", start: 5_100, end: 5_900, text: "there",
                    words: [Segment.Word(start: 5_100, end: 5_500, text: "there")]),
        ]
        XCTAssertEqual(merged, singlePass)
    }

    // MARK: A file still being written

    func testCopySamplesReadsWhatTheWriterHasAppended() throws {
        let url = FilesTests.root.appendingPathComponent("open-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url, startHostSeconds: 0)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<16_000 { channel[0][i] = 0.25 }
        writer.append(buffer, hostSeconds: nil)
        let frames = writer.framesWritten
        XCTAssertGreaterThan(frames, 0)
        let copy = FilesTests.root.appendingPathComponent("copy-\(UUID().uuidString).wav")
        try AudioFiles.copySamples(url, 0..<frames, to: copy)
        let live = try Data(contentsOf: url)
        let copied = try Data(contentsOf: copy)
        XCTAssertEqual(Data(copied.dropFirst(44)), Data(live.dropFirst(44).prefix(frames * 2)))
        XCTAssertEqual(copied.count, 44 + frames * 2)
        writer.close()
    }

    // MARK: Helpers

    private func tone(_ frames: Int, _ amplitude: Int16) -> [Int16] {
        Array(repeating: amplitude, count: frames * SpeechChunks.frame)
    }

    private func writeTone(seconds: Int, to url: URL) throws -> Data {
        let n = seconds * rate
        var data = WavWriter.header(dataBytes: UInt32(n * 2))
        var pcm = Data(count: n * 2)
        pcm.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<n { samples[i] = 1000 }
        }
        data.append(pcm)
        try data.write(to: url)
        return data
    }
}

/// A frame count the live transcriber can read off the main thread.
private final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int
    init(_ n: Int) { self.n = n }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return n }
        set { lock.lock(); n = newValue; lock.unlock() }
    }
}
