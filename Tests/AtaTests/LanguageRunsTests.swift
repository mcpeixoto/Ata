@testable import Ata
import XCTest

/// Someone who speaks Portuguese and English switches between them in one call.
/// Each stretch of speech gets its own language, instead of one per track.
final class LanguageRunsTests: XCTestCase {
    private func d(_ code: String, _ p: Double) -> (code: String, p: Double)? { (code, p) }

    func testEachStretchKeepsTheLanguageItWasSpokenIn() {
        let runs = LanguageChoice.runs([d("pt", 0.97), d("pt", 0.93), d("en", 0.95), d("en", 0.9), d("pt", 0.96)],
                                       seconds: [8, 12, 6, 9, 10], plausible: ["pt", "en"], fallback: "pt")
        XCTAssertEqual(runs, [.init(pieces: 0..<2, language: "pt"),
                              .init(pieces: 2..<4, language: "en"),
                              .init(pieces: 4..<5, language: "pt")])
    }

    func testAShortOrUnsurePieceIsNotASwitch() {
        // A two-second "okay" heard as English, and a mumble nobody could place.
        let runs = LanguageChoice.runs([d("pt", 0.95), d("en", 0.99), d("pt", 0.4), nil, d("pt", 0.9)],
                                       seconds: [10, 2, 7, 5, 8], plausible: ["pt", "en"], fallback: "en")
        XCTAssertEqual(runs, [.init(pieces: 0..<5, language: "pt")])
    }

    func testALanguageNobodySpeaksIsIgnored() {
        // Large v3 has heard UK English as Welsh at p 0.99.
        let runs = LanguageChoice.runs([d("en", 0.9), d("cy", 0.99), d("en", 0.92)],
                                       seconds: [10, 10, 10], plausible: ["pt", "en"], fallback: "pt")
        XCTAssertEqual(runs, [.init(pieces: 0..<3, language: "en")])
    }

    func testTheStartTakesTheFirstSureAnswer() {
        let runs = LanguageChoice.runs([nil, d("pt", 0.5), d("en", 0.95), d("pt", 0.95)],
                                       seconds: [5, 5, 5, 5], plausible: ["pt", "en"], fallback: "pt")
        XCTAssertEqual(runs, [.init(pieces: 0..<3, language: "en"), .init(pieces: 3..<4, language: "pt")])
    }

    func testNothingSureFallsBackToOneLanguage() {
        let runs = LanguageChoice.runs([nil, nil], seconds: [5, 5], plausible: ["pt", "en"], fallback: "pt")
        XCTAssertEqual(runs, [.init(pieces: 0..<2, language: "pt")])
        XCTAssertEqual(LanguageChoice.runs([], seconds: [], plausible: ["pt"], fallback: "pt"), [])
    }

    func testDetectionsAreReadPerFileFromOneWhisperRun() {
        let files = (0..<3).map { URL(fileURLWithPath: "/tmp/m/piece-\($0).wav") }
        // whisper-cli's log for three files; the second one detected nothing.
        let log = """
        whisper_init_from_file_with_params_no_state: loading model from 'ggml-large-v3-q5_0.bin'

        main: processing '/tmp/m/piece-0.wav' (128000 samples, 8.0 sec), 8 threads, 1 processors, 5 beams + best of 5, lang = auto, task = transcribe, timestamps = 1 ...
        whisper_full_with_state: auto-detected language: pt (p = 0.973118)

        main: processing '/tmp/m/piece-1.wav' (32000 samples, 2.0 sec), 8 threads, 1 processors, 5 beams + best of 5, lang = auto, task = transcribe, timestamps = 1 ...

        main: processing '/tmp/m/piece-2.wav' (160000 samples, 10.0 sec), 8 threads, 1 processors, 5 beams + best of 5, lang = auto, task = transcribe, timestamps = 1 ...
        whisper_full_with_state: auto-detected language: en (p = 0.912000)
        """
        let found = LocalEngine.parseDetections(log, files: files)
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found[0]?.code, "pt")
        XCTAssertEqual(found[0]?.p ?? 0, 0.973118, accuracy: 1e-9)
        XCTAssertNil(found[1], "a file without a detection is not given the next file's answer")
        XCTAssertEqual(found[2]?.code, "en")
    }

    func testASegmentFromAPieceMovesBackIntoTheTrack() {
        let s = Segment(speaker: "me", start: 100, end: 900, text: "olá a todos",
                        words: [.init(start: 100, end: 300, text: "olá"), .init(start: 400, end: 900, text: "todos")])
        let moved = s.shifted(by: 60_000)
        XCTAssertEqual(moved.start, 60_100)
        XCTAssertEqual(moved.end, 60_900)
        XCTAssertEqual(moved.words.map(\.start), [60_100, 60_400])
        XCTAssertEqual(moved.text, s.text)
    }

    // MARK: Cutting at pauses

    private let rate = Int(WavWriter.sampleRate)
    private var frame: Int { SpeechChunks.frame }

    /// An envelope in dB: `true` stretches are speech, `false` are pauses.
    private func envelope(_ parts: [(seconds: Double, speech: Bool)]) -> [Double] {
        var rng = SystemRandomNumberGenerator()
        return parts.flatMap { part in
            (0..<(Int(part.seconds * Double(rate)) / frame)).map { _ in
                (part.speech ? -20 : -70) + Double.random(in: -3...3, using: &rng)
            }
        }
    }

    private func assertCovers(_ pieces: [Range<Int>], _ samples: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pieces.first?.lowerBound, 0, file: file, line: line)
        XCTAssertEqual(pieces.last?.upperBound, samples, file: file, line: line)
        for i in 1..<max(1, pieces.count) {
            XCTAssertEqual(pieces[i - 1].upperBound, pieces[i].lowerBound, "back to back", file: file, line: line)
        }
    }

    func testATrackIsCutInThePausesAndLongSpeechIsCutToo() {
        let db = envelope([(5, true), (1, false), (8, true), (1, false), (2, true), (1, false), (70, true), (1, false), (2, true)])
        let samples = db.count * frame
        let pieces = SpeechChunks.pieces(db: db, samples: samples)
        assertCovers(pieces, samples)
        let seconds = pieces.map { Double($0.count) / Double(rate) }
        XCTAssertEqual(seconds[0], 5.5, accuracy: 0.2, "the first cut is in the middle of the first pause")
        XCTAssertEqual(seconds[1], 9, accuracy: 0.2)
        XCTAssertTrue(seconds.allSatisfy { $0 <= SpeechChunks.maxSeconds + SpeechChunks.minSeconds }, "\(seconds)")
        XCTAssertTrue(seconds.dropLast().allSatisfy { $0 >= SpeechChunks.minSeconds }, "\(seconds)")
    }

    func testMostlySilenceAndShortTracksStillGiveWholePieces() {
        let quiet = envelope([(30, false), (5, true), (1, false), (6, true), (60, false)])
        assertCovers(SpeechChunks.pieces(db: quiet, samples: quiet.count * frame), quiet.count * frame)

        let short = envelope([(3, true)])
        XCTAssertEqual(SpeechChunks.pieces(db: short, samples: short.count * frame), [0..<(short.count * frame)])
        XCTAssertEqual(SpeechChunks.pieces(db: [], samples: 0), [])
    }

    func testAWavFileIsCutWhereItIsQuiet() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-pieces-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 6 s of tone, 1 s of silence, 7 s of tone.
        var pcm: [Int16] = []
        for (seconds, loud) in [(6.0, true), (1.0, false), (7.0, true)] {
            for i in 0..<Int(seconds * Double(rate)) {
                pcm.append(loud ? Int16(8000 * sin(2 * .pi * 300 * Double(i) / Double(rate))) : 0)
            }
        }
        var data = WavWriter.header(dataBytes: UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        let wav = dir.appendingPathComponent("mic.wav")
        try data.write(to: wav)

        let pieces = try SpeechChunks.split(wav)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(Double(pieces[0].upperBound) / Double(rate), 6.5, accuracy: 0.1)
        assertCovers(pieces, pcm.count)

        // A piece copied out holds exactly those samples.
        let piece = dir.appendingPathComponent("piece.wav")
        try AudioFiles.copySamples(wav, pieces[1], to: piece)
        XCTAssertEqual(WavWriter.duration(of: piece), Double(pieces[1].count) / Double(rate), accuracy: 0.001)
        let copied = try Data(contentsOf: piece).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(copied, Array(pcm[pieces[1]]))
    }
}
