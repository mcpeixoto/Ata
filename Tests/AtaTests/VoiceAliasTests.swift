@testable import Ata
import XCTest

/// Comparing names people actually write.
final class NameTests: XCTestCase {
    func testTheSameNameWrittenDifferentlyIsTheSameName() {
        XCTAssertEqual(Names.compare("Rita Alves", "rita alves"), .exact)
        XCTAssertEqual(Names.compare("João Dias", "Joao Dias"), .exact)
        XCTAssertEqual(Names.compare("Rita  Alves ", "Rita Alves"), .exact)
        XCTAssertEqual(Names.compare("Rita Alves (Acme)", "Rita Alves"), .exact)
        XCTAssertEqual(Names.compare("Rita Alves | Engineering", "Rita Alves"), .exact)
    }

    func testALastNameFirstIsStillTheSamePerson() {
        XCTAssertEqual(Names.compare("Alves, Rita", "Rita Alves"), .reordered)
    }

    /// The commonest real case, and the weakest: a voice named from what someone
    /// is called out loud, against an invitation with their full name.
    func testAFirstNameMatchesWeakly() {
        XCTAssertEqual(Names.compare("Rita", "Rita Alves"), .firstName)
        XCTAssertEqual(Names.compare("Rita Alves", "Rita"), .firstName)
    }

    func testTwoDifferentPeopleDoNotMatch() {
        XCTAssertEqual(Names.compare("Rita Alves", "Rita Sousa"), .none)
        XCTAssertEqual(Names.compare("Rita", "João"), .none)
        XCTAssertEqual(Names.compare("", "Rita"), .none)
    }

    func testAMatchIsOrderedByHowSureItIs() {
        XCTAssertTrue(Names.Match.exact > .reordered)
        XCTAssertTrue(Names.Match.reordered > .firstName)
        XCTAssertTrue(Names.Match.firstName > .none)
    }

    func testAnAddressIsOnePersonHoweverItIsWritten() {
        XCTAssertEqual(Names.normalise(email: "mailto:Rita@Acme.com"), "rita@acme.com")
        XCTAssertEqual(Names.normalise(email: "rita+calendar@acme.com"), "rita@acme.com")
        XCTAssertNil(Names.normalise(email: "rita"), "not an address")
        XCTAssertNil(Names.normalise(email: "@acme.com"))
    }

    /// An invitation with an address and no name still has to show something
    /// the user recognises.
    func testAnAddressCanStandInForAName() {
        XCTAssertEqual(Names.nameFromEmail("mailto:rita.alves@acme.com"), "rita.alves")
        XCTAssertNil(Names.nameFromEmail("nonsense"))
    }
}

/// Keeping both names when two voices turn out to be one person.
///
/// Folding "Rita Alves" into "Rita" used to throw "Rita Alves" away — and with
/// it the one string that would have matched her on the next invitation. The
/// merge made Ata worse at recognising exactly the person it had just been told
/// about.
final class VoiceAliasTests: XCTestCase {
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

    private func speaker(_ label: String, _ axis: Int) -> MeetingSpeaker {
        var e = [Float](repeating: 0, count: 8)
        e[axis] = 1
        return MeetingSpeaker(label: label, embedding: e, seconds: 30, voiceID: nil)
    }

    private func voice(_ name: String?, aliases: [String]? = nil) -> Voice {
        Voice(id: UUID(), name: name, centroid: [1, 0, 0, 0], observations: 1, meetingIDs: [],
              sample: nil, firstSeen: Date(), lastSeen: Date(), isMe: false, number: 1,
              model: VoiceLibrary.model, aliases: aliases)
    }

    func testMergingKeepsTheNameItDoesNotUse() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", 0), speaker("S2", 3)], meetingID: "m1")
        let source = lib.voices[0].id, target = lib.voices[1].id
        lib.rename(source, to: "Rita Alves")
        lib.rename(target, to: "Rita")

        lib.merge(source, into: target)

        let kept = try! XCTUnwrap(lib.voices.first { $0.id == target })
        XCTAssertEqual(kept.name, "Rita", "transcripts still say what they said")
        XCTAssertEqual(kept.aliases, ["Rita Alves"], "and the other name is not lost")
        XCTAssertEqual(kept.allNames, ["Rita", "Rita Alves"])
    }

    func testMergingTwoUnnamedVoicesWritesNothingExtra() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", 0), speaker("S2", 3)], meetingID: "m1")
        lib.merge(lib.voices[0].id, into: lib.voices[1].id)
        XCTAssertNil(lib.voices[0].aliases, "no key in the file for nothing")
    }

    func testAChainOfMergesDoesNotStackTheSameName() {
        XCTAssertEqual(VoiceLibrary.aliases(keeping: "Rita",
                                            from: [voice("rita"), voice("Rita "), voice("Rita Alves")]),
                       ["Rita Alves"])
    }

    func testAliasesSurviveBeingSavedAndReadBack() throws {
        let encoder = VoiceLibrary.encoder(), decoder = VoiceLibrary.decoder()
        let read = try decoder.decode(Voice.self, from: try encoder.encode(voice("Rita", aliases: ["Rita Alves"])))
        XCTAssertEqual(read.aliases, ["Rita Alves"])
    }

    /// Every voice file written before 2.11.
    func testAVoiceFromBeforeAliasesStillReads() throws {
        let json = """
        {"id":"8B9D4E0A-0000-0000-0000-000000000001","centroid":[1,0,0,0],"observations":1,
         "meetingIDs":[],"firstSeen":"2026-01-01T00:00:00.000Z","lastSeen":"2026-01-01T00:00:00.000Z",
         "isMe":false,"name":"Rita"}
        """
        let v = try VoiceLibrary.decoder().decode(Voice.self, from: Data(json.utf8))
        XCTAssertNil(v.aliases)
        XCTAssertEqual(v.allNames, ["Rita"])
    }

    // MARK: Two devices

    func testTwoDevicesEachKeepTheirAliases() throws {
        var mac = voice("Rita", aliases: ["Rita Alves"])
        var phone = mac
        phone.aliases = ["rita@acme.com"]
        mac.aliases = ["Rita Alves"]

        let a = VoiceLibrary.Version(voice: mac, modified: Date(timeIntervalSince1970: 1_800_000_100))
        let b = VoiceLibrary.Version(voice: phone, modified: Date(timeIntervalSince1970: 1_800_000_900))
        let merged = try XCTUnwrap(VoiceLibrary.merge(versions: [a, b]))

        XCTAssertEqual(Set(merged.aliases ?? []), ["Rita Alves", "rita@acme.com"], "a union, not a choice")
        XCTAssertEqual(VoiceLibrary.merge(versions: [b, a]), merged, "both devices settle it the same way")
    }

    /// The downgrade: an older Ata re-encoded the voice and dropped the key.
    /// The device that still has them brings them back.
    func testADeviceThatLostItsAliasesGetsThemBack() throws {
        let full = voice("Rita", aliases: ["Rita Alves"])
        var stripped = full
        stripped.aliases = nil

        let a = VoiceLibrary.Version(voice: full, modified: Date(timeIntervalSince1970: 1_800_000_100))
        let b = VoiceLibrary.Version(voice: stripped, modified: Date(timeIntervalSince1970: 1_800_000_900))
        XCTAssertEqual(try XCTUnwrap(VoiceLibrary.merge(versions: [a, b])).aliases, ["Rita Alves"])
    }

    /// The subtle one. An alias added on the phone must not drag the phone's
    /// stale name over a rename made on the Mac — which is why `addAlias`
    /// leaves `edited` alone.
    func testAnAliasDoesNotOverrideARename() throws {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", 0)], meetingID: "m1")
        let id = lib.voices[0].id
        lib.rename(id, to: "Rita")
        let beforeAlias = lib.voices[0].edited
        lib.addAlias(id, "Rita Alves")
        XCTAssertEqual(lib.voices[0].edited, beforeAlias, "adding an alias is not an edit to the name")

        // The Mac renamed later; the phone only added an alias.
        var renamed = lib.voices[0]
        renamed.name = "Rita Sousa"
        renamed.edited = Date(timeIntervalSince1970: 1_800_009_000)
        let mac = VoiceLibrary.Version(voice: renamed, modified: Date(timeIntervalSince1970: 1_800_009_000))
        let phone = VoiceLibrary.Version(voice: lib.voices[0], modified: Date(timeIntervalSince1970: 1_800_009_500))

        let merged = try XCTUnwrap(VoiceLibrary.merge(versions: [mac, phone]))
        XCTAssertEqual(merged.name, "Rita Sousa", "the rename wins")
        XCTAssertEqual(Set(merged.aliases ?? []), ["Rita", "Rita Alves"], "and nothing is thrown away")
    }

    func testAddingAnAliasTwiceChangesNothing() {
        let lib = VoiceLibrary(file: file)
        lib.assign([speaker("S1", 0)], meetingID: "m1")
        let id = lib.voices[0].id
        lib.rename(id, to: "Rita")
        lib.addAlias(id, "Rita Alves")
        lib.addAlias(id, "rita alves")
        lib.addAlias(id, "Rita")
        XCTAssertEqual(lib.voices[0].aliases, ["Rita Alves"])

        lib.removeAlias(id, "RITA ALVES")
        XCTAssertNil(lib.voices[0].aliases)
    }
}
