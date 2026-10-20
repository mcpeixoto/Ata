@testable import Ata
import XCTest

final class VoiceLibraryTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString).json")
        VoiceLibrary.matchThreshold = 0.6
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
