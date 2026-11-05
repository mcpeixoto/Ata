import XCTest
@testable import Ata

/// Word times after VAD. Numbers from a real whisper-cli 1.9.5 run on six
/// sentences placed at known moments, with pauses of two to three seconds
/// between them: the last one, "Coffee", starts at 31.40 s in the audio,
/// and whisper.cpp reported its token at 19.11 s.
final class WordTimingVADTests: XCTestCase {
    private let log = """
    whisper_vad: Including segment 0: 0.69 - 4.56 (duration: 3.87)
    whisper_vad: vad_segment_info: orig_start: 0.69, orig_end: 4.46, vad_start: 0.00, vad_end: 3.77
    whisper_vad: vad_segment_info: orig_start: 6.00, orig_end: 9.48, vad_start: 3.97, vad_end: 7.45
    whisper_vad: vad_segment_info: orig_start: 12.53, orig_end: 15.82, vad_start: 7.65, vad_end: 10.94
    whisper_vad: vad_segment_info: orig_start: 18.90, orig_end: 22.28, vad_start: 11.14, vad_end: 14.52
    whisper_vad: vad_segment_info: orig_start: 25.62, orig_end: 29.42, vad_start: 14.72, vad_end: 18.52
    whisper_vad: vad_segment_info: orig_start: 31.25, orig_end: 34.96, vad_start: 18.72, vad_end: 22.43
    whisper_vad: Created time mapping table with 17 points
    """

    private func token(_ text: String, _ from: Int, _ to: Int) -> LocalEngine.Token {
        try! JSONDecoder().decode(LocalEngine.Token.self,
                                  from: Data(#"{"text":\#(String(reflecting: text)),"offsets":{"from":\#(from),"to":\#(to)}}"#.utf8))
    }

    func testWordsAfterAPauseLandWhereTheyAreHeard() {
        let timeline = LocalEngine.VADTimeline(log: log)
        // First tokens of sentences 1, 2 and 6, on whisper's packed timeline.
        let words = LocalEngine.words([token(" The", 260, 360), token(" Pl", 4200, 4510), token("ias", 4510, 4630),
                                       token(" Our", 7900, 8100), token(" Coffee", 19110, 19500)],
                                      timeline: timeline)
        XCTAssertEqual(words.map(\.text), ["The", "Plias", "Our", "Coffee"])
        let heard = [1000, 6300, 12700, 31400]
        for (w, real) in zip(words, heard) {
            XCTAssertEqual(Double(w.start), Double(real), accuracy: 300, "\(w.text) at \(w.start) ms")
        }
    }

    func testPointsMatchWhisperCppsTable() {
        let timeline = LocalEngine.VADTimeline(log: log)
        // The count whisper.cpp logged for this run: two per chunk and two per pause, less duplicates.
        XCTAssertEqual(timeline.points.count, 17)
        XCTAssertEqual(timeline.original(ms: 3970), 6000)   // next chunk starts
        XCTAssertEqual(timeline.original(ms: 3870), 4460)   // the pause starts
        XCTAssertEqual(timeline.original(ms: 1885), 2575)   // halfway through the first chunk
        XCTAssertEqual(timeline.original(ms: 30000), 34960) // past the end
    }

    func testWithoutVADTimesAreUnchanged() {
        let timeline = LocalEngine.VADTimeline(log: "whisper_full: no VAD here\n")
        XCTAssertEqual(timeline.original(ms: 12345), 12345)
        let words = LocalEngine.words([token(" hello", 5000, 5400)], timeline: timeline)
        XCTAssertEqual(words.first?.start, 5000)
    }
}
