@testable import Ata
import XCTest

/// Following a meeting while it plays: word times kept in the transcript, the
/// word under the playhead, clickable words, and the waveform.
final class FollowAlongTests: XCTestCase {
    typealias Word = StoredTranscript.Word

    // MARK: Word times in the transcript

    func testTranscriptsFromBefore25StillOpen() throws {
        let old = """
        {"coarse":false,"engine":"local","model":"large-v3","segments":[{"end":2000,"speaker":"me","start":0,"text":"Olá a todos"}]}
        """
        let t = try JSONDecoder().decode(StoredTranscript.self, from: Data(old.utf8))
        XCTAssertNil(t.segments[0].words)
        XCTAssertEqual(WordTiming.words(of: t.segments[0]).map(\.text), ["Olá", "a", "todos"], "estimated instead")
    }

    func testWordTimesSurviveSavingAndJoiningLines() throws {
        let t = StoredTranscript(segments: [
            .init(start: 0, end: 1_000, text: "Shall we", speaker: Speakers.me,
                  words: [Word(start: 0, end: 400, text: "Shall"), Word(start: 500, end: 1_000, text: "we")]),
            .init(start: 1_200, end: 2_000, text: "start now", speaker: Speakers.me),  // no word times
        ], coarse: false, summary: nil, engine: "local", model: "large-v3")
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(StoredTranscript.self, from: data), t)

        let block = try XCTUnwrap(Transcriber.blocks(t).first)
        XCTAssertEqual(block.text, "Shall we start now")
        XCTAssertEqual(block.words?.map(\.text), ["Shall", "we", "start", "now"])
        XCTAssertEqual(block.words?.prefix(2).map(\.start), [0, 500], "real times are kept")
        XCTAssertEqual(block.words?[2].start, 1_200, "the line without times is estimated from its own span")
    }

    func testEstimatesFillTheLineInOrderAndByLength() {
        let line = StoredTranscript.Line(start: 1_000, end: 3_000, text: "a  bbbbbbb  cc", speaker: Speakers.me)
        let w = WordTiming.estimate(line)
        XCTAssertEqual(w.map(\.text), ["a", "bbbbbbb", "cc"])
        XCTAssertEqual(w.first?.start, 1_000)
        XCTAssertEqual(w.last?.end, 3_000)
        for (a, b) in zip(w, w.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 1) }
        XCTAssertGreaterThan(w[1].end - w[1].start, w[0].end - w[0].start, "a longer word gets longer")
        XCTAssertEqual(WordTiming.estimate(.init(start: 0, end: 0, text: "  ", speaker: Speakers.me)), [])
    }

    func testOpenAIWordsGoToTheSegmentTheyFallIn() {
        let segments = [(start: 0, end: 2_000, text: "Hello there"), (start: 2_500, end: 4_000, text: "General Kenobi")]
        let words = [(start: 100, end: 600, text: "Hello"), (start: 700, end: 1_900, text: "there"),
                     (start: 2_300, end: 2_450, text: "General"),  // in the gap, nearer the second
                     (start: 3_000, end: 3_900, text: "Kenobi")]
        let attached = OpenAIEngine.attach(words: words, to: segments)
        XCTAssertEqual(attached.map { ws in ws.map { $0.text } }, [["Hello", "there"], ["General", "Kenobi"]])
        XCTAssertEqual(OpenAIEngine.attach(words: words, to: []).count, 0)
    }

    // MARK: The word under the playhead

    private func line(_ id: Int, _ start: Int, _ end: Int, _ words: [(Int, String)]) -> MeetingModel.Line {
        MeetingModel.Line(id: id, start: start, end: end, speaker: Speakers.me, name: "Alex", text: "",
                          words: words.map { Word(start: $0.0, end: $0.0 + 300, text: $0.1) })
    }

    func testThePlayheadFindsTheLineAndWordBeingHeard() {
        let lines = [line(0, 1_000, 3_000, [(1_000, "one"), (1_500, "two"), (2_400, "three")]),
                     line(1, 6_000, 7_000, [(6_000, "four")])]
        let lead = WordTiming.leadMs
        XCTAssertNil(PlaybackCursor.at(500, in: lines), "nothing yet")
        XCTAssertEqual(PlaybackCursor.at(1_000 - lead, in: lines), PlaybackCursor(line: 0, word: 0), "a word lights up just before it")
        XCTAssertEqual(PlaybackCursor.at(1_800, in: lines), PlaybackCursor(line: 0, word: 1))
        XCTAssertEqual(PlaybackCursor.at(2_900, in: lines), PlaybackCursor(line: 0, word: 2))
        XCTAssertEqual(PlaybackCursor.at(4_500, in: lines), PlaybackCursor(line: 0, word: nil), "in the pause, the line stays but no word")
        XCTAssertEqual(PlaybackCursor.at(60_000, in: lines), PlaybackCursor(line: 1, word: nil))
        XCTAssertEqual(PlaybackCursor.at(6_100, in: lines), PlaybackCursor(line: 1, word: 0))
    }

    func testBinarySearchMatchesAPlainScan() {
        let starts = [0, 10, 10, 20, 35, 80]
        for t in -5...90 {
            XCTAssertEqual(PlaybackCursor.lastIndex(in: starts, atOrBefore: t), starts.lastIndex { $0 <= t }, "t = \(t)")
        }
        XCTAssertNil(PlaybackCursor.lastIndex(in: [], atOrBefore: 5))
    }

    func testAWordLinksToItsMoment() throws {
        let url = SeekLink.url(ms: 61_234)
        XCTAssertEqual(SeekLink.ms(url), 61_234)
        XCTAssertNil(SeekLink.ms(try XCTUnwrap(URL(string: "https://example.com/t/5"))), "other links are left alone")
        XCTAssertEqual(SeekLink.ms(SeekLink.url(ms: -20)), 0)
    }

    // MARK: Waveform

    private func wav(_ samples: [Int16], at url: URL) throws {
        var data = WavWriter.header(dataBytes: UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    func testTheWaveformIsLoudWhereSomeoneSpeaksAndKeepsBothLanesInStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-wave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = Int(WavWriter.sampleRate)
        // You: one loud second, then a quiet second. The others: two seconds of silence, then a loud half second.
        let mic = (0..<(2 * rate)).map { i in i < rate ? Int16(16_000 * sin(Double(i) * 0.2)) : 0 }
        let system = [Int16](repeating: 0, count: 2 * rate) + (0..<(rate / 2)).map { Int16(16_000 * sin(Double($0) * 0.3)) }
        let micURL = dir.appendingPathComponent("mic.wav"), systemURL = dir.appendingPathComponent("system.wav")
        try wav(mic, at: micURL)
        try wav(system, at: systemURL)

        let w = try Waveform.compute(mic: micURL, system: systemURL)
        XCTAssertEqual(w.count, 50, "2.5 s in 50 ms buckets")
        XCTAssertEqual(w.me.count, w.others.count, "the shorter lane is padded with silence")
        XCTAssertGreaterThan(w.me[5], 200)
        XCTAssertEqual(w.me[30], 0)
        XCTAssertEqual(w.others[10], 0)
        XCTAssertGreaterThan(w.others[45], 200)

        let file = dir.appendingPathComponent("waveform.bin")
        try w.write(to: file)
        XCTAssertEqual(Waveform.read(from: file), w)
        try Data("nonsense".utf8).write(to: file)
        XCTAssertNil(Waveform.read(from: file))
        XCTAssertEqual(try Waveform.compute(mic: micURL, system: nil).others.allSatisfy { $0 == 0 }, true)
    }

    func testLevelsSpanSixtyDecibels() {
        XCTAssertEqual(Waveform.level(rms: 1), 255)
        XCTAssertEqual(Waveform.level(rms: 0), 0)
        XCTAssertEqual(Waveform.level(rms: 0.001), 0, "−60 dBFS is the floor")
        XCTAssertEqual(Int(Waveform.level(rms: 0.0316)), 128, accuracy: 2, "−30 dBFS is halfway")
    }
}
