@testable import Ata
import XCTest

/// Telling Ata which voice is yours.
///
/// The Mac learns your voice from the microphone track of a call. An iPhone
/// records one track, so `SpeakerRoute` never chooses `.call` there and the
/// in-person route refuses to learn a guess — which left a phone-only library
/// with no fingerprint of you, for ever. Marking a voice as yourself by hand is
/// the way out, so these tests cover that mark: that it holds, that it is the
/// only one, that it survives two devices, and that it reaches transcripts.
final class MyVoiceTests: XCTestCase {
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

    private func v(_ axis: Int, noise: Float = 0, dims: Int = 8) -> [Float] {
        var x = [Float](repeating: 0, count: dims)
        x[axis] = 1
        x[(axis + 1) % dims] = noise
        return x
    }

    private func speaker(_ label: String, _ e: [Float]) -> MeetingSpeaker {
        MeetingSpeaker(label: label, embedding: e, seconds: 30, voiceID: nil)
    }

    // MARK: Marking a voice as yourself

    func testMarkingAVoiceAsYourselfMakesItYourFingerprint() {
        let lib = VoiceLibrary(file: file)
        let assigned = lib.assign([speaker("S1", v(0)), speaker("S2", v(3))], meetingID: "m1")
        XCTAssertTrue(lib.myFingerprints.isEmpty, "a phone-only library knows no voice as yours")

        let mine = try! XCTUnwrap(assigned.first?.voiceID)
        lib.setMe(mine, true)

        XCTAssertEqual(lib.voice(mine)?.isMe, true)
        XCTAssertEqual(lib.myFingerprints.count, 1)
        XCTAssertEqual(lib.myFingerprints.first, lib.voice(mine)?.centroid)
        XCTAssertNotNil(lib.voice(mine)?.edited, "set by hand, so the later edit wins over iCloud")
    }

    func testOnlyOneVoiceIsYoursAtATime() {
        let lib = VoiceLibrary(file: file)
        let assigned = lib.assign([speaker("S1", v(0)), speaker("S2", v(3))], meetingID: "m1")
        let first = assigned[0].voiceID!, second = assigned[1].voiceID!

        lib.setMe(first, true)
        lib.setMe(second, true)

        XCTAssertEqual(lib.voice(first)?.isMe, false, "a mistaken tap doesn't leave two people as you")
        XCTAssertEqual(lib.voice(second)?.isMe, true)
        XCTAssertEqual(lib.myFingerprints.count, 1)
    }

    func testTakingTheMarkBackLeavesNoFingerprintOfYou() {
        let lib = VoiceLibrary(file: file)
        let mine = lib.assign([speaker("S1", v(0))], meetingID: "m1")[0].voiceID!
        lib.setMe(mine, true)
        lib.setMe(mine, false)

        XCTAssertEqual(lib.voice(mine)?.isMe, false)
        XCTAssertTrue(lib.myFingerprints.isEmpty)
    }

    /// A voice the Mac learned as you from a call is not a by-hand mark, so
    /// marking another voice must not quietly unlearn it.
    func testMarkingAVoiceLeavesAVoiceLearnedFromACallAlone() {
        let lib = VoiceLibrary(file: file)
        let learned = lib.assign([speaker(Speakers.me, v(0))], meetingID: "m1")[0].voiceID!
        XCTAssertEqual(lib.voice(learned)?.isMe, true, "the call route learns you from the microphone")

        let other = lib.assign([speaker("S1", v(3))], meetingID: "m2")[0].voiceID!
        lib.setMe(other, true)

        XCTAssertEqual(lib.voice(learned)?.isMe, true)
        XCTAssertEqual(lib.myFingerprints.count, 2)
    }

    // MARK: The deadlock this breaks

    /// With no fingerprint of you, the in-person route guesses whoever talked
    /// longest and says so; once you have marked your voice, it knows.
    func testTheRoomKnowsYouOnceYouHaveMarkedYourVoice() {
        let turns = [SpeakerTurn(start: 0, end: 10_000, label: "A"),
                     SpeakerTurn(start: 10_000, end: 40_000, label: "B")]
        let clusters = InPerson.clusters(turns, embeddings: ["A": v(0), "B": v(3)])

        let guess = try! XCTUnwrap(InPerson.me(among: clusters, fingerprints: []))
        XCTAssertEqual(guess.label, "B", "the longest talker, for want of anything better")
        XCTAssertFalse(guess.recognised, "and a guess is never learned as your voice")

        let lib = VoiceLibrary(file: file)
        let mine = lib.assign([speaker("S1", v(0))], meetingID: "m1")[0].voiceID!
        lib.setMe(mine, true)

        let known = try! XCTUnwrap(InPerson.me(among: clusters, fingerprints: lib.myFingerprints))
        XCTAssertEqual(known.label, "A", "you are the voice you marked, not the one that talked most")
        XCTAssertTrue(known.recognised)
    }

    // MARK: Two devices

    func testTakingTheMarkBackOnOneDeviceBeatsTheOtherDevicesCopy() throws {
        let id = UUID()
        let base = Voice(id: id, name: nil, centroid: [1, 0, 0], observations: 2, meetingIDs: ["m1"],
                         sample: nil, firstSeen: Date(timeIntervalSince1970: 1_800_000_000),
                         lastSeen: Date(timeIntervalSince1970: 1_800_000_100),
                         isMe: true, number: 1, model: VoiceLibrary.model)
        // The iPhone says it was never you…
        var corrected = base
        corrected.isMe = false
        corrected.edited = Date(timeIntervalSince1970: 1_800_000_500)
        // …while the Mac still holds the version that was marked.
        let stale = base

        let a = VoiceLibrary.Version(voice: corrected, modified: Date(timeIntervalSince1970: 1_800_000_500))
        let b = VoiceLibrary.Version(voice: stale, modified: Date(timeIntervalSince1970: 1_800_000_900))
        let merged = try XCTUnwrap(VoiceLibrary.merge(versions: [a, b]))

        XCTAssertFalse(merged.isMe, "the hand that corrected it decides, as a name does")
        XCTAssertEqual(VoiceLibrary.merge(versions: [b, a]), merged, "both devices settle it the same way")
    }

    /// Nobody edited by hand: "me" was learned from a call on one device only,
    /// and must still reach the other.
    func testAVoiceLearnedAsYouOnOneDeviceStaysYouOnBoth() throws {
        let id = UUID()
        let base = Voice(id: id, name: nil, centroid: [1, 0, 0], observations: 2, meetingIDs: ["m1"],
                         sample: nil, firstSeen: Date(timeIntervalSince1970: 1_800_000_000),
                         lastSeen: Date(timeIntervalSince1970: 1_800_000_100),
                         isMe: false, number: 1, model: VoiceLibrary.model)
        var learned = base
        learned.isMe = true

        let a = VoiceLibrary.Version(voice: learned, modified: Date(timeIntervalSince1970: 1_800_000_200))
        let b = VoiceLibrary.Version(voice: base, modified: Date(timeIntervalSince1970: 1_800_000_900))
        let merged = try XCTUnwrap(VoiceLibrary.merge(versions: [a, b]))

        XCTAssertTrue(merged.isMe)
        XCTAssertEqual(VoiceLibrary.merge(versions: [b, a]), merged)
    }

    // MARK: Transcripts

    /// A transcript already written keeps the name it shows. In the meeting that
    /// got you wrong, its "me" label is the bad guess — if the voice you marked
    /// also read as your name, one person's name would sit on two speakers. The
    /// mark fixes the meetings after it, and "Transcribe again" fixes this one.
    func testMarkingAVoiceDoesNotRewriteTheNameInAnAlreadyWrittenTranscript() throws {
        let lib = VoiceLibrary(file: file)
        let mine = try XCTUnwrap(lib.assign([speaker("S1", v(0))], meetingID: "m1")[0].voiceID)
        lib.setMe(mine, true)

        let voice = try XCTUnwrap(lib.voice(mine))
        XCTAssertTrue(voice.isMe)
        XCTAssertEqual(voice.displayName, L("Voice %d", 1), "still its own name, not yours")
    }
}

/// Running a transcript again in another language. The iPhone has one engine, so
/// "Transcribe again with…" is a Mac menu; the language, though, is the usual
/// reason to re-run on a phone, and it travels in the same one-off override.
final class LanguageOverrideTests: XCTestCase {
    private func meeting() -> Meeting {
        Meeting(id: "t", startedAt: Date(), endedAt: nil, duration: nil, app: nil,
                status: .pending, error: nil)
    }

    func testAOneOffLanguageWinsOverSettings() {
        var m = meeting()
        m.override = TranscribeOverride(engine: Engine.apple.rawValue,
                                        model: AppleSpeechEngine.modelID, language: "pt")
        let o = TranscribeOptions.current(for: m)
        XCTAssertEqual(o.language, "pt")
        XCTAssertEqual(o.engine, .apple)
    }

    func testAnOverrideWithNoLanguageLeavesTheSettingAlone() {
        let fromSettings = TranscribeOptions.current().language
        var m = meeting()
        m.override = TranscribeOverride(engine: Engine.apple.rawValue, model: AppleSpeechEngine.modelID)
        XCTAssertEqual(TranscribeOptions.current(for: m).language, fromSettings)
    }

    /// An override saved by Ata 2.7 has no language field at all.
    func testAnOverrideFromAnEarlierAtaStillReads() throws {
        let json = Data(#"{"engine":"openai","model":"whisper-1"}"#.utf8)
        let override = try JSONDecoder().decode(TranscribeOverride.self, from: json)
        XCTAssertEqual(override.engine, "openai")
        XCTAssertNil(override.language)
    }
}

/// What the People tab lists. A voice heard in one meeting used to fall through
/// every section — not named, not yet worth asking about, not hidden — so a first
/// recording's voices appeared nowhere while the footer counted them.
final class VoiceListingTests: XCTestCase {
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

    private func v(_ axis: Int, dims: Int = 8) -> [Float] {
        var x = [Float](repeating: 0, count: dims)
        x[axis] = 1
        return x
    }

    private func speaker(_ label: String, _ e: [Float]) -> MeetingSpeaker {
        MeetingSpeaker(label: label, embedding: e, seconds: 30, voiceID: nil)
    }

    /// The rule `PeopleModel.heardOnce` applies, on the library it reads.
    private func heardOnce(_ lib: VoiceLibrary) -> [Voice] {
        lib.voices.filter { $0.name == nil && !$0.isMe && !$0.isDismissed && !$0.isExcluded
            && $0.meetings < VoiceLibrary.askAfterMeetings }
    }

    func testAVoiceFromASingleMeetingIsListed() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0))], meetingID: "m1")

        XCTAssertTrue(lib.worthAsking.isEmpty, "one meeting is not yet worth asking about")
        XCTAssertEqual(heardOnce(lib).count, 1, "but it is not invisible either")
    }

    func testAVoiceStopsBeingHeardOnceWhenItIsWorthAsking() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", v(0))], meetingID: "m1")
        lib.assign([speaker("S1", v(0))], meetingID: "m2")

        XCTAssertEqual(lib.worthAsking.count, 1)
        XCTAssertTrue(heardOnce(lib).isEmpty, "listed once, in one section at a time")
    }

    func testYourOwnVoiceAndDismissedOnesAreNotListedAsHeardOnce() {
        let lib = VoiceLibrary(file: file)
        let mine = lib.assign([speaker("S1", v(0))], meetingID: "m1")[0].voiceID!
        let other = lib.assign([speaker("S1", v(3))], meetingID: "m2")[0].voiceID!
        lib.setMe(mine, true)
        lib.setDismissed(other, true)

        XCTAssertTrue(heardOnce(lib).isEmpty)
    }
}
