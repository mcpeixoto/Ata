@testable import Ata
import XCTest

/// One person, one voice — and knowing which one is you.
///
/// Every test here stands for a way voice recognition used to come apart in a
/// real room, found while tracking down "it isn't identifying the voices":
///
/// - the diarizer hears one person as two, so the library grew a near-identical
///   copy of them every meeting, and a name the user had given stopped sticking.
///   The pair itself still happens — two speakers of one meeting are two people
///   as far as the library is concerned, and "Same person as" merges them — but
///   it no longer breeds;
/// - a microphone that held a whole room was learned as your voice;
/// - the speaker Ata only guessed was you was thrown away, so the person it had
///   mistaken for you could never be told apart, named or corrected.
final class VoiceIdentityTests: XCTestCase {
    private var file: URL!
    private var savedThreshold: Float = 0
    private var savedLead: Float = 0

    override func setUp() {
        super.setUp()
        file = FileManager.default.temporaryDirectory.appendingPathComponent("voices-\(UUID().uuidString).json")
        savedThreshold = VoiceLibrary.matchThreshold
        savedLead = VoiceLibrary.requiredLead
        VoiceLibrary.matchThreshold = 0.6
        VoiceLibrary.requiredLead = 0.1
    }

    override func tearDown() {
        VoiceLibrary.matchThreshold = savedThreshold
        VoiceLibrary.requiredLead = savedLead
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    /// One person, heard slightly differently each time. `tilt` moves the voice a
    /// little off its own axis, as a different microphone or a different room
    /// does: every value here stays well above `matchThreshold` of the others.
    private func sameVoice(tilt: Float, dims: Int = 8) -> [Float] {
        var x = [Float](repeating: 0, count: dims)
        x[0] = 1
        x[1] = tilt
        return x
    }

    /// Somebody else entirely: a different axis, so cosine with `sameVoice` is 0.
    private func otherVoice(_ axis: Int, dims: Int = 8) -> [Float] {
        var x = [Float](repeating: 0, count: dims)
        x[axis] = 1
        return x
    }

    private func speaker(_ label: String, _ embedding: [Float], seconds: Double = 30) -> MeetingSpeaker {
        MeetingSpeaker(label: label, embedding: embedding, seconds: seconds, voiceID: nil)
    }

    // MARK: One person, one voice

    func testTwoPeopleInOneMeetingStillGetTwoVoices() {
        let lib = VoiceLibrary(file: file)
        let out = lib.assign([speaker("S1", otherVoice(0)), speaker("S2", otherVoice(3))], meetingID: "m1")

        XCTAssertEqual(lib.voices.count, 2)
        XCTAssertNotEqual(out[0].voiceID, out[1].voiceID)
    }

    /// The ratchet this fixes: with two near-identical voices already in the
    /// library, neither could win the lead test, so every later meeting minted
    /// another copy — and the name on one of them was never used again.
    func testAVoiceIsMatchedEvenWhenTheLibraryHoldsItsOwnDuplicate() {
        let lib = VoiceLibrary(file: file)
        // A duplicate pair for one person, as an earlier over-split or an iCloud
        // race leaves behind: built with matching turned off, so the fixture does
        // not depend on the bug it stands for.
        VoiceLibrary.matchThreshold = 0.999
        lib.assign([speaker("S1", sameVoice(tilt: 0.2))], meetingID: "m1")
        lib.assign([speaker("S1", sameVoice(tilt: 0.3))], meetingID: "m2")
        VoiceLibrary.matchThreshold = 0.6
        XCTAssertEqual(lib.voices.count, 2, "the fixture needs the duplicate pair")
        lib.rename(lib.voices[0].id, to: "Ana")

        let out = lib.assign([speaker("S1", sameVoice(tilt: 0.25))], meetingID: "m3")

        XCTAssertEqual(lib.voices.count, 2, "no third copy of the same person")
        let matched = out[0].voiceID.flatMap { id in lib.voices.first { $0.id == id } }
        XCTAssertNotNil(matched, "the speaker was matched, not left unassigned")
        XCTAssertTrue(matched?.meetingIDs.contains("m3") == true, "the match learned from this meeting")
    }

    func testTwoDifferentPeopleWhoSoundAlikeStillBlockEachOther() {
        let lib = VoiceLibrary(file: file)
        // Far enough apart to be two people by the library's own rule, close
        // enough to the newcomer that neither wins by the required lead.
        lib.assign([speaker("S1", otherVoice(0))], meetingID: "m1")
        lib.assign([speaker("S1", otherVoice(1))], meetingID: "m2")

        var between = [Float](repeating: 0, count: 8)
        between[0] = 1
        between[1] = 1
        let out = lib.assign([speaker("S1", between)], meetingID: "m3")

        XCTAssertEqual(lib.voices.count, 3, "a coin-flip between two people becomes a voice of its own")
        XCTAssertTrue(lib.voices.contains { $0.id == out[0].voiceID })
    }

    // MARK: Your own voice

    func testRecordingYourVoiceMarksItAsYours() {
        let lib = VoiceLibrary(file: file)
        let me = lib.enrolMe(embedding: sameVoice(tilt: 0.2))

        XCTAssertTrue(me.isMe)
        XCTAssertEqual(lib.myFingerprints.count, 1)
        XCTAssertNotNil(me.edited, "a mark made by hand is stamped, so another device's edit can be ordered")
    }

    func testRecordingYourVoiceMarksTheVoiceAlreadyHeardInMeetings() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", sameVoice(tilt: 0.2))], meetingID: "m1")
        let heard = lib.voices[0].id

        let me = lib.enrolMe(embedding: sameVoice(tilt: 0.25))

        XCTAssertEqual(lib.voices.count, 1, "your recording is not a second you")
        XCTAssertEqual(me.id, heard, "the voice from that meeting is the one marked")
        XCTAssertEqual(me.meetingIDs, ["m1"], "so that meeting's transcript can be drawn again")
    }

    func testRecordingYourVoiceAgainReplacesTheOneMarkedByHand() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", otherVoice(4))], meetingID: "m1")
        lib.setMe(lib.voices[0].id, true)
        XCTAssertEqual(lib.myFingerprints.count, 1)

        let me = lib.enrolMe(embedding: sameVoice(tilt: 0.2))

        XCTAssertEqual(lib.myFingerprints.count, 1, "one voice at a time is yours")
        XCTAssertEqual(lib.voices.filter(\.isMe).map(\.id), [me.id], "and it is the one just recorded")
    }

    /// Without headphones the microphone carries the others back through the
    /// speaker. One such call used to put "this is you" on a named colleague and
    /// average your voice into theirs, with no way back but forgetting them.
    func testAMicrophoneTrackNeverMarksANamedPersonAsYou() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", sameVoice(tilt: 0.2))], meetingID: "m1")
        lib.rename(lib.voices[0].id, to: "Ana")

        lib.assign([speaker(Speakers.me, sameVoice(tilt: 0.25))], meetingID: "m2")

        XCTAssertEqual(lib.voices.first { $0.name == "Ana" }?.isMe, false, "Ana is not you")
        XCTAssertTrue(lib.myFingerprints.isEmpty)
    }

    func testAMicrophoneTrackStillLearnsAnUnnamedVoiceAsYou() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", sameVoice(tilt: 0.2))], meetingID: "m1")

        lib.assign([speaker(Speakers.me, sameVoice(tilt: 0.25))], meetingID: "m2")

        XCTAssertEqual(lib.myFingerprints.count, 1)
    }

    // MARK: Correcting a guess

    func testARecognisedYouNeedsNoCorrection() {
        let mine = UUID()
        let assigned = [MeetingSpeaker(label: Speakers.me, embedding: [], seconds: 10, voiceID: mine)]
        XCTAssertNil(InPerson.correction(guessed: false, assigned: assigned, myVoices: [mine]))
    }

    func testAGuessStandsWhenNothingElseIsKnownToBeYou() {
        let assigned = [MeetingSpeaker(label: Speakers.guessedMe, embedding: [], seconds: 10, voiceID: UUID()),
                        MeetingSpeaker(label: "S1", embedding: [], seconds: 5, voiceID: UUID())]
        XCTAssertNil(InPerson.correction(guessed: true, assigned: assigned, myVoices: [UUID()]))
    }

    func testTheLibraryBeatsTheGuessAboutWhichSpeakerIsYou() {
        let mine = UUID()
        let assigned = [MeetingSpeaker(label: Speakers.guessedMe, embedding: [], seconds: 40, voiceID: UUID()),
                        MeetingSpeaker(label: "S1", embedding: [], seconds: 5, voiceID: mine)]
        XCTAssertEqual(InPerson.correction(guessed: true, assigned: assigned, myVoices: [mine]), "S1",
                       "the speaker the library knows as you takes the me label; the guess takes S1")
    }

    // MARK: Which track is which

    func testASystemTrackThatCouldNotBeReadIsStillTreatedAsACall() {
        // Guessing "in person" here diarized the microphone of a real call —
        // your voice with the others' echo over it — as a roomful of people.
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: nil, hasMic: true, systemUnreadable: true), .call)
    }

    func testWithNoSystemTrackAtAllItIsStillInPerson() {
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: nil, hasMic: true, systemUnreadable: false), .inPerson)
    }

    func testAQuietParticipantIsStillLearned() {
        XCTAssertLessThanOrEqual(FluidDiarizer.minimumSecondsToLearn, 5.0,
                                 "ten seconds of a whole meeting left short meetings with no voices at all")
    }
}
