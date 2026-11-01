@testable import Ata
import XCTest

final class VoiceLibraryTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString).json")
        VoiceLibrary.matchThreshold = 0.6
        VoiceLibrary.requiredLead = 0.1
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    /// A unit vector along `axis`, nudged by `noise` on the next axis.
    private func v(_ axis: Int, noise: Float = 0, dims: Int = 8) -> [Float] {
        var x = [Float](repeating: 0, count: dims)
        x[axis] = 1
        x[(axis + 1) % dims] = noise
        return x
    }

    private func speaker(_ label: String, _ e: [Float]) -> MeetingSpeaker {
        MeetingSpeaker(label: label, embedding: e, seconds: 30, voiceID: nil)
    }

    func testTheSameVoiceIsRecognisedInALaterMeeting() {
        let lib = VoiceLibrary(file: file)
        let first = lib.assign([speaker("S1", v(0)), speaker("S2", v(3))], meetingID: "m1")
        let second = lib.assign([speaker("S1", v(3, noise: 0.2)), speaker("S2", v(5))], meetingID: "m2")

        XCTAssertEqual(lib.voices.count, 3, "two from m1, one new in m2")
        XCTAssertEqual(second[0].voiceID, first[1].voiceID, "S1 of m2 is S2 of m1")
        XCTAssertNotEqual(second[1].voiceID, first[0].voiceID)
        XCTAssertEqual(lib.voice(first[1].voiceID)?.meetingIDs, ["m1", "m2"])
        XCTAssertEqual(lib.voice(first[1].voiceID)?.observations, 2)
    }

    func testTwoSpeakersInOneMeetingNeverShareAVoice() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0))], meetingID: "m1")
        // Both resemble the known voice; only the closer one may take it.
        let out = lib.assign([speaker("S1", v(0, noise: 0.5)), speaker("S2", v(0, noise: 0.1))], meetingID: "m2")
        XCTAssertNotEqual(out[0].voiceID, out[1].voiceID)
        XCTAssertEqual(out[1].voiceID, lib.voices.first?.id, "the closer embedding wins")
    }

    func testAnAmbiguousVoiceIsNotForcedOntoEitherCandidate() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0)), speaker("S2", v(1))], meetingID: "m1")
        // Halfway between both known voices: similar enough to each, but neither clearly.
        let between: [Float] = [1, 1, 0, 0, 0, 0, 0, 0]
        VoiceLibrary.matchThreshold = 0.6
        let out = lib.assign([speaker("S1", between)], meetingID: "m2")
        XCTAssertEqual(lib.voices.count, 3, "becomes a new voice")
        XCTAssertNotEqual(out[0].voiceID, lib.voices[0].id)
        XCTAssertNotEqual(out[0].voiceID, lib.voices[1].id)
    }

    func testBelowTheThresholdIsANewVoice() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0))], meetingID: "m1")
        lib.assign([speaker("S1", v(1))], meetingID: "m2")  // orthogonal: similarity 0
        XCTAssertEqual(lib.voices.count, 2)
    }

    func testTheMicTrackMarksTheUser() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("me", v(2))], meetingID: "m1")
        XCTAssertTrue(lib.voices[0].isMe)
        XCTAssertTrue(lib.worthAsking.isEmpty, "never ask the user who they are")
    }

    func testOnlyRecurringUnnamedVoicesAreWorthAsking() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0)), speaker("S2", v(4))], meetingID: "m1")
        XCTAssertTrue(lib.worthAsking.isEmpty)
        lib.assign([speaker("S1", v(0))], meetingID: "m2")
        XCTAssertEqual(lib.worthAsking.count, 1)
        lib.rename(lib.worthAsking[0].id, to: "  Rita ")
        XCTAssertTrue(lib.worthAsking.isEmpty)
        XCTAssertTrue(lib.voices.contains { $0.name == "Rita" }, "names are trimmed")
    }

    func testMergingFoldsMeetingsAndKeepsTheName() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0)), speaker("S2", v(4))], meetingID: "m1")
        lib.assign([speaker("S1", v(4))], meetingID: "m2")
        let a = lib.voices[0].id, b = lib.voices[1].id
        lib.rename(b, to: "João")
        lib.merge(a, into: b)
        XCTAssertEqual(lib.voices.count, 1)
        XCTAssertEqual(lib.voices[0].name, "João")
        XCTAssertEqual(lib.voices[0].meetingIDs, ["m1", "m2"])
        XCTAssertEqual(lib.voices[0].observations, 3)
        XCTAssertEqual(lib.voices[0].centroid.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-5)
    }

    func testTheLibrarySurvivesARestart() throws {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0))], meetingID: "m1")
        lib.rename(lib.voices[0].id, to: "Ana")
        try lib.save()
        let reopened = VoiceLibrary(file: file)
        XCTAssertEqual(reopened.voices.count, 1)
        var a = reopened.voices[0], b = lib.voices[0]
        // Saved as ISO 8601, which keeps milliseconds; compare dates to that precision.
        XCTAssertEqual(a.firstSeen.timeIntervalSince1970, b.firstSeen.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(a.lastSeen.timeIntervalSince1970, b.lastSeen.timeIntervalSince1970, accuracy: 0.001)
        a.firstSeen = b.firstSeen; a.lastSeen = b.lastSeen
        XCTAssertEqual(a, b)
    }

    func testCosine() {
        XCTAssertEqual(VoiceLibrary.cosine([1, 0], [1, 0]), 1, accuracy: 1e-6)
        XCTAssertEqual(VoiceLibrary.cosine([1, 0], [0, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(VoiceLibrary.cosine([1, 0], [-1, 0]), -1, accuracy: 1e-6)
        XCTAssertEqual(VoiceLibrary.cosine([1, 2], [1]), 0, "mismatched sizes never match")
    }
}

final class SpeakerAssignmentTests: XCTestCase {
    let turns = [
        SpeakerTurn(start: 0, end: 5_000, label: "S1"),
        SpeakerTurn(start: 5_000, end: 9_000, label: "S2"),
        SpeakerTurn(start: 20_000, end: 25_000, label: "S1"),
    ]

    func testTheMostOverlappingTurnWins() {
        XCTAssertEqual(SpeakerAssignment.label(start: 4_000, end: 8_000, turns: turns), "S2")
        XCTAssertEqual(SpeakerAssignment.label(start: 1_000, end: 5_500, turns: turns), "S1")
    }

    func testANearMissWithinASecondStillCounts() {
        XCTAssertEqual(SpeakerAssignment.label(start: 9_400, end: 10_000, turns: turns), "S2")
    }

    func testNobodyNearbyMeansNoLabel() {
        XCTAssertNil(SpeakerAssignment.label(start: 12_000, end: 15_000, turns: turns))
    }
}

final class WordSplitTests: XCTestCase {
    private func token(_ text: String, _ from: Int, _ to: Int) -> LocalEngine.Token {
        try! JSONDecoder().decode(LocalEngine.Token.self,
                                  from: Data(#"{"text":\#(String(reflecting: text)),"offsets":{"from":\#(from),"to":\#(to)}}"#.utf8))
    }

    func testTokensBecomeWordsWithPunctuationAttached() {
        let words = LocalEngine.words([
            token("[_BEG_]", 0, 0), token(" list", 8610, 8840), token(".", 8840, 8850),
            token(" Sounds", 9090, 9380), token(" good", 9480, 9640), token("[_TT_500]", 9640, 9640),
        ])
        XCTAssertEqual(words.map(\.text), ["list.", "Sounds", "good"])
        XCTAssertEqual(words[0].end, 8850)
    }

    func testASegmentIsSplitWhereTheSpeakerChanges() {
        let words: [Segment.Word] = [
            .init(start: 6170, end: 6480, text: "with"), .init(start: 8610, end: 8840, text: "list."),
            .init(start: 9090, end: 9380, text: "Sounds"), .init(start: 9480, end: 9640, text: "good."),
        ]
        let s = Segment(speaker: "others", start: 6160, end: 9640, text: "with list. Sounds good.", words: words)
        let turns = [SpeakerTurn(start: 0, end: 8900, label: "S1"), SpeakerTurn(start: 9000, end: 16000, label: "S2")]
        let pieces = SpeakerAssignment.split(s, turns: turns)
        XCTAssertEqual(pieces.map(\.speaker), ["S1", "S2"])
        XCTAssertEqual(pieces.map(\.text), ["with list.", "Sounds good."])
        XCTAssertEqual(pieces[1].start, 9090)
    }

    func testAChangeLandingMidPhraseMovesToThePause() {
        // As measured: Whisper times "list" late, so the turns hand it to the next speaker,
        // but the real pause is after "list".
        let words: [Segment.Word] = [
            .init(start: 7990, end: 8230, text: "the"), .init(start: 8230, end: 8610, text: "press"),
            .init(start: 8610, end: 8840, text: "list."), .init(start: 9090, end: 9380, text: "Sounds"),
            .init(start: 9480, end: 9640, text: "good."),
        ]
        let s = Segment(speaker: "others", start: 7990, end: 9640, text: "", words: words)
        let turns = [SpeakerTurn(start: 0, end: 8600, label: "S1"), SpeakerTurn(start: 8600, end: 16000, label: "S2")]
        XCTAssertEqual(SpeakerAssignment.split(s, turns: turns).map(\.text), ["the press list.", "Sounds good."])
    }

    func testAChangeMovesToTheSentenceEnd() {
        // As measured in meeting two: "Great" (the next speaker's first word) was
        // timed into the previous turn because "now." was stretched over the silence.
        let words: [Segment.Word] = [
            .init(start: 5000, end: 5400, text: "done"), .init(start: 5400, end: 6900, text: "now."),
            .init(start: 6900, end: 7200, text: "Great"), .init(start: 7300, end: 7600, text: "news."),
        ]
        let s = Segment(speaker: "others", start: 5000, end: 7600, text: "", words: words)
        let turns = [SpeakerTurn(start: 0, end: 7250, label: "S1"), SpeakerTurn(start: 7250, end: 9000, label: "S2")]
        XCTAssertEqual(SpeakerAssignment.split(s, turns: turns).map(\.text), ["done now.", "Great news."])
    }

    func testAChangeAlreadyAtAPauseStays() {
        let words: [Segment.Word] = [
            .init(start: 0, end: 300, text: "one"), .init(start: 300, end: 600, text: "two"),
            .init(start: 1200, end: 1500, text: "three"), .init(start: 1500, end: 1800, text: "four"),
        ]
        let s = Segment(speaker: "others", start: 0, end: 1800, text: "", words: words)
        let turns = [SpeakerTurn(start: 0, end: 900, label: "S1"), SpeakerTurn(start: 900, end: 2000, label: "S2")]
        XCTAssertEqual(SpeakerAssignment.split(s, turns: turns).map(\.text), ["one two", "three four"])
    }

    func testWithoutWordsTheWholeSegmentGoesToTheMainSpeaker() {
        let s = Segment(speaker: "others", start: 0, end: 10_000, text: "hello")
        let turns = [SpeakerTurn(start: 0, end: 3_000, label: "S1"), SpeakerTurn(start: 3_000, end: 10_000, label: "S2")]
        XCTAssertEqual(SpeakerAssignment.split(s, turns: turns).map(\.speaker), ["S2"])
    }
}

final class VoiceLibraryConsistencyTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString).json")
        VoiceLibrary.matchThreshold = 0.6
        VoiceLibrary.requiredLead = 0.1
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    private func s(_ label: String, _ axis: Int) -> MeetingSpeaker {
        var e = [Float](repeating: 0, count: 8); e[axis] = 1
        return MeetingSpeaker(label: label, embedding: e, seconds: 30, voiceID: nil)
    }

    func testTranscribingTheSameMeetingAgainDoesNotCountItTwice() {
        let lib = VoiceLibrary(file: file)
        lib.assign([s("S1", 0)], meetingID: "m1")
        lib.assign([s("S1", 0)], meetingID: "m1")
        XCTAssertEqual(lib.voices.count, 1)
        XCTAssertEqual(lib.voices[0].observations, 1)
        XCTAssertEqual(lib.voices[0].meetingIDs, ["m1"])
    }

    func testDeletingAMeetingForgetsOnlyTheVoicesItAloneIntroduced() {
        let lib = VoiceLibrary(file: file)
        lib.assign([s("S1", 0), s("S2", 3)], meetingID: "m1")
        lib.assign([s("S1", 0)], meetingID: "m2")
        let named = lib.voices.first { $0.meetingIDs == ["m1"] }!
        lib.assign([s("S1", 5)], meetingID: "m3")
        lib.rename(lib.voices.first { $0.meetingIDs == ["m3"] }!.id, to: "Ana")

        let gone = lib.removeMeeting("m1")
        XCTAssertEqual(gone.map(\.id), [named.id], "the unnamed voice heard only in m1 goes")
        XCTAssertEqual(lib.voices.first { $0.meetingIDs.contains("m2") }?.meetingIDs, ["m2"], "the shared voice stays")
        _ = lib.removeMeeting("m3")
        XCTAssertTrue(lib.voices.contains { $0.name == "Ana" }, "a named voice is kept even with no meetings")
    }

    func testAnUnreadableLibraryIsNeverOverwritten() throws {
        try Data("not json".utf8).write(to: file)
        let lib = VoiceLibrary(file: file)
        XCTAssertTrue(lib.loadFailed)
        lib.assign([s("S1", 0)], meetingID: "m1")
        XCTAssertThrowsError(try lib.save())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
    }
}

final class SmallRulesTests: XCTestCase {
    func testAnEmptyNameBecomesMe() {
        let saved = Pref.d.string(forKey: Pref.myName)
        defer { Pref.d.set(saved, forKey: Pref.myName) }
        Pref.d.set("   ", forKey: Pref.myName)
        XCTAssertEqual(Pref.myNameOrDefault, "Me")
        Pref.d.set("Rita", forKey: Pref.myName)
        XCTAssertEqual(Pref.myNameOrDefault, "Rita")
    }

}
