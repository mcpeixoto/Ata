@testable import Ata
import XCTest

/// The voice library as one file per voice, so two devices editing different
/// voices never write the same file.
final class VoiceStorageTests: XCTestCase {
    private var dir: URL!
    private var savedThreshold: Float = 0
    private var savedLead: Float = 0
    private let old = Date(timeIntervalSince1970: 1_000_000_000)

    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and voice library, never the real ones
    }

    override func setUp() {
        super.setUp()
        dir = FilesTests.root.appendingPathComponent("voices-\(UUID().uuidString)", isDirectory: true)
        savedThreshold = VoiceLibrary.matchThreshold
        savedLead = VoiceLibrary.requiredLead
        VoiceLibrary.matchThreshold = 0.65
        VoiceLibrary.requiredLead = 0.1
    }

    override func tearDown() {
        VoiceLibrary.matchThreshold = savedThreshold
        VoiceLibrary.requiredLead = savedLead
        VoiceLibrary.model = Diarization.embeddingModel
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func axis(_ i: Int, dims: Int = 8) -> [Float] {
        var x = [Float](repeating: 0, count: dims)
        x[i] = 1
        return x
    }

    private func speaker(_ label: String, _ e: [Float]) -> MeetingSpeaker {
        MeetingSpeaker(label: label, embedding: e, seconds: 30, voiceID: nil)
    }

    private func mtime(_ url: URL) throws -> Date {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    /// Back-dates files, so a later write shows up as a newer modification date.
    private func age(_ urls: [URL]) throws {
        for url in urls {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Three voices, saved: one file each.
    private func threeVoices() throws -> (VoiceLibrary, [UUID]) {
        let lib = VoiceLibrary(directory: dir)
        let out = lib.assign([speaker("S1", axis(0)), speaker("S2", axis(1)), speaker("S3", axis(2))], meetingID: "m1")
        try lib.save()
        return (lib, out.compactMap(\.voiceID))
    }

    // MARK: Migration

    private let legacy = """
    [{"id":"6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F","name":"Rita","centroid":[0.6,0.8,0],"observations":3,
      "meetingIDs":["a","b"],"sample":"6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F.m4a",
      "firstSeen":"2026-10-20T10:00:00.123Z","lastSeen":"2026-10-21T10:00:00.456Z",
      "isMe":false,"number":1,"dismissed":true},
     {"id":"0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9","centroid":[0,0,1],"observations":1,
      "meetingIDs":["b"],"firstSeen":"2026-10-21T10:00:00.000Z","lastSeen":"2026-10-21T10:00:00.000Z",
      "isMe":true,"number":2}]
    """

    func testALibraryFromBefore26MovesToOneFilePerVoiceLosslessly() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("voices.json")
        try legacy.write(to: file, atomically: true, encoding: .utf8)

        let lib = VoiceLibrary(directory: dir)
        XCTAssertFalse(lib.loadFailed)
        XCTAssertEqual(lib.voices.count, 2)
        let rita = try XCTUnwrap(lib.voice(UUID(uuidString: "6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F")))
        let me = try XCTUnwrap(lib.voice(UUID(uuidString: "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9")))

        XCTAssertTrue(exists(lib.url(for: rita.id)), "each voice has its own file")
        XCTAssertTrue(exists(lib.url(for: me.id)))
        XCTAssertFalse(exists(file), "voices.json is put aside…")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("voices.json.migrated"), encoding: .utf8),
                       legacy, "…and kept as it was")

        // Read back from the new files alone: nothing was lost on the way.
        let reopened = VoiceLibrary(directory: dir)
        let r = try XCTUnwrap(reopened.voice(rita.id))
        XCTAssertEqual(r, rita)
        XCTAssertEqual(r.name, "Rita")
        XCTAssertEqual(r.centroid, [0.6, 0.8, 0])
        XCTAssertEqual(r.observations, 3)
        XCTAssertEqual(r.meetingIDs, ["a", "b"])
        XCTAssertEqual(r.sample, "6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F.m4a")
        XCTAssertEqual(r.firstSeen.timeIntervalSince1970, 1_792_490_400.123, accuracy: 0.0005)
        XCTAssertEqual(r.lastSeen.timeIntervalSince1970, 1_792_576_800.456, accuracy: 0.0005)
        XCTAssertEqual(r.number, 1)
        XCTAssertTrue(r.isDismissed)
        XCTAssertFalse(r.isExcluded)
        XCTAssertNil(r.model, "an untagged fingerprint stays untagged until it learns")
        XCTAssertEqual(reopened.voice(me.id), me)
        XCTAssertTrue(try XCTUnwrap(reopened.voice(me.id)).isMe)
    }

    func testAMigrationCutShortIsFinishedTheNextTime() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacy.write(to: dir.appendingPathComponent("voices.json"), atomically: true, encoding: .utf8)
        // As if Ata stopped after writing Rita's file, renamed since, but before the other.
        let first = VoiceLibrary(directory: dir)
        let rita = try XCTUnwrap(UUID(uuidString: "6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F"))
        first.rename(rita, to: "Rita Lopes")
        try first.save()
        try FileManager.default.removeItem(at: first.url(for: try XCTUnwrap(UUID(uuidString: "0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9"))))
        try FileManager.default.moveItem(at: dir.appendingPathComponent("voices.json.migrated"),
                                         to: dir.appendingPathComponent("voices.json"))

        let lib = VoiceLibrary(directory: dir)
        XCTAssertEqual(lib.voices.count, 2)
        XCTAssertEqual(lib.voice(rita)?.name, "Rita Lopes", "a voice's own file wins over voices.json")
        XCTAssertTrue(lib.voices.allSatisfy { exists(lib.url(for: $0.id)) })
        XCTAssertFalse(exists(dir.appendingPathComponent("voices.json")))
        XCTAssertTrue(exists(dir.appendingPathComponent("voices.json.migrated")))
    }

    func testAnUnreadableVoicesJsonIsKeptAndNothingIsBuiltOnTop() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("voices.json")
        try Data("not json".utf8).write(to: file)

        let lib = VoiceLibrary(directory: dir)
        XCTAssertTrue(lib.loadFailed)
        lib.assign([speaker("S1", axis(0))], meetingID: "m1")
        XCTAssertThrowsError(try lib.save())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "not json")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names, ["voices.json"], "no voice files written next to it")
    }

    // MARK: One file per voice

    func testSavingWritesOnlyTheVoicesThatChanged() throws {
        let (lib, ids) = try threeVoices()
        let files = ids.map(lib.url(for:))
        try age(files)
        let untouched = try Data(contentsOf: files[0])

        lib.rename(ids[1], to: "Ana")
        try lib.save()
        XCTAssertEqual(try mtime(files[0]), old)
        XCTAssertEqual(try mtime(files[2]), old)
        XCTAssertNotEqual(try mtime(files[1]), old, "the renamed voice was written")
        XCTAssertEqual(try Data(contentsOf: files[0]), untouched)
        XCTAssertEqual(VoiceLibrary(directory: dir).voice(ids[1])?.name, "Ana")

        // Nothing changed: nothing written.
        try age(files)
        try lib.save()
        XCTAssertEqual(try files.map(mtime), [old, old, old])
    }

    func testForgettingAVoiceRemovesItsFileAndSample() throws {
        let (lib, ids) = try threeVoices()
        let sample = dir.appendingPathComponent("\(ids[0].uuidString).m4a")
        try Data("audio".utf8).write(to: sample)
        lib.setSample(ids[0], file: sample.lastPathComponent)
        try lib.save()
        try age(ids.map(lib.url(for:)))

        lib.forget(ids[0])
        try lib.save()
        XCTAssertFalse(exists(lib.url(for: ids[0])))
        XCTAssertFalse(exists(sample), "its sample goes too")
        XCTAssertEqual(try mtime(lib.url(for: ids[1])), old)
        XCTAssertEqual(try mtime(lib.url(for: ids[2])), old)
        XCTAssertEqual(Set(VoiceLibrary(directory: dir).voices.map(\.id)), Set(ids[1...]))
    }

    func testMergingRemovesOnlyTheMergedVoicesFile() throws {
        let (lib, ids) = try threeVoices()
        let sampleA = dir.appendingPathComponent("\(ids[0].uuidString).m4a")
        let sampleB = dir.appendingPathComponent("\(ids[1].uuidString).m4a")
        try Data("a".utf8).write(to: sampleA)
        try Data("b".utf8).write(to: sampleB)
        lib.setSample(ids[0], file: sampleA.lastPathComponent)
        lib.setSample(ids[1], file: sampleB.lastPathComponent)
        try lib.save()
        try age(ids.map(lib.url(for:)))

        lib.merge(ids[0], into: ids[1])
        try lib.save()
        XCTAssertFalse(exists(lib.url(for: ids[0])), "the merged voice's file is gone")
        XCTAssertFalse(exists(sampleA), "the target kept its own sample, so the other one goes")
        XCTAssertTrue(exists(sampleB))
        XCTAssertNotEqual(try mtime(lib.url(for: ids[1])), old, "the voice it joined was written")
        XCTAssertEqual(try mtime(lib.url(for: ids[2])), old, "the third was not touched")
        let reopened = VoiceLibrary(directory: dir)
        XCTAssertEqual(reopened.voices.count, 2)
        XCTAssertEqual(reopened.voice(ids[1])?.observations, 2)
    }

    func testAMergedVoicesSampleIsKeptWhenItIsHandedOn() throws {
        let (lib, ids) = try threeVoices()
        let sampleA = dir.appendingPathComponent("\(ids[0].uuidString).m4a")
        try Data("a".utf8).write(to: sampleA)
        lib.setSample(ids[0], file: sampleA.lastPathComponent)
        try lib.save()

        lib.merge(ids[0], into: ids[1])
        try lib.save()
        XCTAssertTrue(exists(sampleA), "the voice it joined plays it now")
        XCTAssertEqual(VoiceLibrary(directory: dir).voice(ids[1])?.sample, sampleA.lastPathComponent)
    }

    func testAVoiceAnotherDeviceAddedIsLeftAlone() throws {
        let (here, ids) = try threeVoices()
        // Another device, same folder, adds a voice while this one has the library open.
        let there = VoiceLibrary(directory: dir)
        let added = try XCTUnwrap(there.assign([speaker("S1", axis(5))], meetingID: "m2")[0].voiceID)
        try there.save()

        here.rename(ids[0], to: "Ana")
        try here.save()
        let reopened = VoiceLibrary(directory: dir)
        XCTAssertEqual(reopened.voices.count, 4, "neither device's change was lost")
        XCTAssertEqual(reopened.voice(ids[0])?.name, "Ana")
        XCTAssertNotNil(reopened.voice(added))
    }

    func testAnUnreadableVoiceFileIsNeverOverwrittenOrRemoved() throws {
        let (lib, ids) = try threeVoices()
        // Damaged, half-synced, or written by a newer Ata.
        let broken = UUID()
        let brokenFile = lib.url(for: broken)
        try Data("{\"half\":".utf8).write(to: brokenFile)

        let reopened = VoiceLibrary(directory: dir)
        XCTAssertFalse(reopened.loadFailed, "the other voices still load and save")
        XCTAssertEqual(reopened.voices.count, 3)
        XCTAssertEqual(reopened.unreadable.map(\.lastPathComponent), [brokenFile.lastPathComponent])

        reopened.rename(ids[0], to: "Ana")
        reopened.forgetAll()
        try reopened.save()
        XCTAssertEqual(try String(contentsOf: brokenFile, encoding: .utf8), "{\"half\":")
        XCTAssertFalse(ids.contains { exists(lib.url(for: $0)) })
    }

    func testAVoiceInVoicesJsonNeverReplacesAnUnreadableFileOfItsOwn() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try legacy.write(to: dir.appendingPathComponent("voices.json"), atomically: true, encoding: .utf8)
        let rita = try XCTUnwrap(UUID(uuidString: "6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F"))
        let ritaFile = dir.appendingPathComponent("\(rita.uuidString).json")
        try Data("garbled".utf8).write(to: ritaFile)

        let lib = VoiceLibrary(directory: dir)
        XCTAssertNil(lib.voice(rita))
        XCTAssertEqual(lib.voices.count, 1)
        XCTAssertEqual(try String(contentsOf: ritaFile, encoding: .utf8), "garbled")
    }

    func testOtherFilesInTheFolderAreNotVoices() {
        XCTAssertNotNil(VoiceLibrary.voiceID(fileName: "6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F.json"))
        XCTAssertNil(VoiceLibrary.voiceID(fileName: "6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F.m4a"))
        XCTAssertNil(VoiceLibrary.voiceID(fileName: "voices.json"))
        XCTAssertNil(VoiceLibrary.voiceID(fileName: "voices.json.migrated"))
        XCTAssertNil(VoiceLibrary.voiceID(fileName: ".6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F.json.icloud"))
    }

    // MARK: Embedding model

    func testAVoiceFileFromBeforeTheModelTagStillLoadsAndMatches() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        try """
        {"id":"\(id.uuidString)","centroid":[1,0,0],"observations":2,"meetingIDs":["a"],
         "firstSeen":"2026-10-20T10:00:00.000Z","lastSeen":"2026-10-20T10:00:00.000Z","isMe":false,"number":1}
        """.write(to: dir.appendingPathComponent("\(id.uuidString).json"), atomically: true, encoding: .utf8)

        let lib = VoiceLibrary(directory: dir)
        XCTAssertNil(lib.voice(id)?.model)
        let out = lib.assign([speaker("S1", [1, 0, 0])], meetingID: "b")
        XCTAssertEqual(out[0].voiceID, id, "untagged fingerprints are from the model in use")
        XCTAssertEqual(lib.voice(id)?.model, Diarization.embeddingModel, "tagged once it learns")
    }

    func testNewVoicesRecordTheModel() {
        let lib = VoiceLibrary(directory: dir)
        lib.assign([speaker("S1", axis(0))], meetingID: "m1")
        XCTAssertEqual(lib.voices[0].model, Diarization.embeddingModel)
    }

    func testVoicesFromAnotherModelAreNeverMatched() throws {
        let lib = VoiceLibrary(directory: dir)
        let first = lib.assign([speaker("me", axis(0)), speaker("S1", axis(1))], meetingID: "m1")
        XCTAssertEqual(lib.myFingerprints.count, 1)

        VoiceLibrary.model = "a newer embedding model"
        let second = lib.assign([speaker("S1", axis(1))], meetingID: "m2")
        XCTAssertNotEqual(second[0].voiceID, first[1].voiceID, "the same numbers mean nothing across models")
        XCTAssertEqual(lib.voices.count, 3)
        XCTAssertEqual(lib.voice(second[0].voiceID)?.model, "a newer embedding model")
        XCTAssertTrue(lib.myFingerprints.isEmpty, "your old fingerprint can't find you either")
        XCTAssertEqual(lib.voice(first[1].voiceID)?.observations, 1, "the old voice did not learn")
    }

    func testMergingAcrossModelsKeepsTheFingerprintStillInUse() throws {
        let lib = VoiceLibrary(directory: dir)
        let oldVoice = try XCTUnwrap(lib.assign([speaker("S1", axis(0))], meetingID: "m1")[0].voiceID)
        VoiceLibrary.model = "a newer embedding model"
        let newVoice = try XCTUnwrap(lib.assign([speaker("S1", axis(3))], meetingID: "m2")[0].voiceID)

        lib.merge(newVoice, into: oldVoice)
        let merged = try XCTUnwrap(lib.voice(oldVoice))
        XCTAssertEqual(merged.centroid, axis(3))
        XCTAssertEqual(merged.model, "a newer embedding model")
        XCTAssertEqual(merged.meetingIDs, ["m1", "m2"])
    }
}

/// One microphone in a room with several people: who is you, and who is not.
final class InPersonTests: XCTestCase {
    private var savedThreshold: Float = 0
    private var savedLead: Float = 0

    override func setUp() {
        super.setUp()
        savedThreshold = VoiceLibrary.matchThreshold
        savedLead = VoiceLibrary.requiredLead
        VoiceLibrary.matchThreshold = 0.65
        VoiceLibrary.requiredLead = 0.1
    }

    override func tearDown() {
        VoiceLibrary.matchThreshold = savedThreshold
        VoiceLibrary.requiredLead = savedLead
        super.tearDown()
    }

    private let mine: [Float] = [1, 0, 0, 0]

    private func cluster(_ label: String, _ e: [Float]?, _ seconds: Double) -> InPerson.Cluster {
        InPerson.Cluster(label: label, embedding: e, seconds: seconds)
    }

    func testTheClusterThatSoundsLikeYouIsYou() {
        let clusters = [cluster("A", [0, 1, 0, 0], 300), cluster("B", [0.95, 0.1, 0.1, 0], 120)]
        XCTAssertEqual(InPerson.me(among: clusters, fingerprints: [mine]),
                       InPerson.Me(label: "B", recognised: true), "even though the other one spoke more")
    }

    func testAnyOfYourFingerprintsCounts() {
        let clusters = [cluster("A", [0, 1, 0, 0], 300), cluster("B", [0, 0, 1, 0], 120)]
        XCTAssertEqual(InPerson.me(among: clusters, fingerprints: [mine, [0, 0, 1, 0]])?.label, "B")
    }

    func testWithoutAFingerprintWhoeverSpokeMostIsYou() {
        let clusters = [cluster("A", [0, 1, 0, 0], 100), cluster("B", [1, 0, 0, 0], 250), cluster("C", nil, 5)]
        XCTAssertEqual(InPerson.me(among: clusters, fingerprints: []), InPerson.Me(label: "B", recognised: false))
    }

    func testNobodySoundingLikeYouFallsBackToMostSpeech() {
        let clusters = [cluster("A", [0, 1, 0, 0], 100), cluster("B", [0, 0, 1, 0], 250)]
        XCTAssertEqual(InPerson.me(among: clusters, fingerprints: [mine]), InPerson.Me(label: "B", recognised: false))
    }

    /// Changed in 2.9: this used to expect a guess. Both clusters clear the
    /// threshold and neither beats the other by the required lead — but they also
    /// sound like each other, which means one person the diarizer split in two.
    /// Either of them is you, so the longer one is, and it is recognised rather
    /// than guessed. Treating it as unknown handed the meeting to "whoever talked
    /// most", who could be somebody else entirely.
    func testTwoClustersThatAreBothYouAreRecognisedAsTheLongerOne() {
        let clusters = [cluster("A", [0.9, 0.3, 0, 0], 100), cluster("B", [0.9, 0, 0.35, 0], 250)]
        XCTAssertEqual(InPerson.me(among: clusters, fingerprints: [mine]), InPerson.Me(label: "B", recognised: true))
    }

    /// The lead rule still holds where it was meant to: two people who happen to
    /// resemble you, but not each other, are still an ambiguity worth refusing.
    func testTwoDifferentPeopleWhoBothResembleYouAreStillAGuess() {
        let clusters = [cluster("A", [0.8, 0.6, 0, 0], 100), cluster("B", [0.8, 0, 0.6, 0], 250)]
        XCTAssertEqual(InPerson.me(among: clusters, fingerprints: [mine]), InPerson.Me(label: "B", recognised: false))
    }

    func testAShortClusterWithoutAFingerprintIsNeverMatched() {
        let clusters = [cluster("A", nil, 4), cluster("B", [0, 1, 0, 0], 60)]
        XCTAssertEqual(InPerson.me(among: clusters, fingerprints: [mine]), InPerson.Me(label: "B", recognised: false))
    }

    func testNobodySpeakingMeansNobodyIsYou() {
        XCTAssertNil(InPerson.me(among: [], fingerprints: [mine]))
    }

    func testClustersAddUpEachSpeakersTime() {
        let turns = [SpeakerTurn(start: 0, end: 2_000, label: "x"), SpeakerTurn(start: 2_000, end: 3_000, label: "y"),
                     SpeakerTurn(start: 3_000, end: 6_500, label: "x")]
        let clusters = InPerson.clusters(turns, embeddings: ["x": mine])
        XCTAssertEqual(clusters, [cluster("x", mine, 5.5), cluster("y", nil, 1)])
    }

    func testYouBecomeMeAndTheOthersAreNumberedInOrder() {
        let turns = [SpeakerTurn(start: 0, end: 1_000, label: "spk2"), SpeakerTurn(start: 1_000, end: 2_000, label: "spk0"),
                     SpeakerTurn(start: 2_000, end: 3_000, label: "spk1"), SpeakerTurn(start: 3_000, end: 4_000, label: "spk2")]
        XCTAssertEqual(InPerson.labels(turns, me: "spk0"), ["spk0": Speakers.me, "spk2": "S1", "spk1": "S2"])
        XCTAssertEqual(InPerson.labels(turns, me: nil), ["spk2": "S1", "spk0": "S2", "spk1": "S3"])
    }

    /// The far side of a call already took S1 and S2. The people on the
    /// microphone continue from there, so the two tracks don't share a number.
    func testRoomSpeakersContinueTheNumbersTheCallAlreadyUsed() {
        let turns = [SpeakerTurn(start: 0, end: 1_000, label: "spk2"), SpeakerTurn(start: 1_000, end: 2_000, label: "spk0")]
        XCTAssertEqual(InPerson.labels(turns, me: "spk0", othersFrom: 3), ["spk0": Speakers.me, "spk2": "S3"])
    }

    func testASpeakerTheLibraryKnowsAsYouIsYouToo() {
        let myVoice = UUID(), someone = UUID()
        let assigned = [MeetingSpeaker(label: Speakers.me, embedding: mine, seconds: 60, voiceID: myVoice),
                        MeetingSpeaker(label: "S1", embedding: [0, 1, 0, 0], seconds: 30, voiceID: someone),
                        MeetingSpeaker(label: "S2", embedding: [0.9, 0, 0, 0.4], seconds: 20, voiceID: myVoice),
                        MeetingSpeaker(label: "S3", embedding: [0, 0, 1, 0], seconds: 10, voiceID: nil)]
        XCTAssertEqual(InPerson.alsoMe(assigned, myVoices: [myVoice]), ["S2"])
    }

    /// The microphone's lines are split at the word where the speaker changes,
    /// exactly as the system track's are on a call.
    func testMicrophoneLinesSplitWhereTheSpeakerChanges() {
        let words: [Segment.Word] = [
            .init(start: 0, end: 300, text: "Shall"), .init(start: 300, end: 600, text: "we"),
            .init(start: 600, end: 1_000, text: "start?"), .init(start: 1_400, end: 1_700, text: "Yes,"),
            .init(start: 1_700, end: 2_100, text: "please."),
        ]
        let s = Segment(speaker: Speakers.me, start: 0, end: 2_100, text: "Shall we start? Yes, please.", words: words)
        let turns = [SpeakerTurn(start: 0, end: 1_200, label: Speakers.me), SpeakerTurn(start: 1_200, end: 3_000, label: "S1")]
        let pieces = SpeakerAssignment.split(s, turns: turns)
        XCTAssertEqual(pieces.map(\.speaker), [Speakers.me, "S1"])
        XCTAssertEqual(pieces.map(\.text), ["Shall we start?", "Yes, please."])
    }
}

/// Which track tells the speakers apart.
final class SpeakerRouteTests: XCTestCase {
    /// `seconds` of sound in a track `total` seconds long, as waveform levels.
    private func levels(sound seconds: Double, of total: Double) -> [UInt8] {
        let n = Int(total * 1000) / Waveform.bucketMs
        let loud = Int(seconds * 1000) / Waveform.bucketMs
        return (0..<n).map { $0 < loud ? 200 : 0 }
    }

    func testACallIsDiarizedOnTheSystemTrack() {
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 600, of: 1_800), hasMic: true), .call)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 600, of: 1_800), hasMic: false), .call)
    }

    func testNoSystemTrackMeansInPerson() {
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: nil, hasMic: true), .inPerson)
    }

    func testASilentSystemTrackMeansInPerson() {
        // A Mac records the system track in every meeting, silent when nothing plays.
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 0, of: 3_600), hasMic: true), .inPerson)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: [], hasMic: true), .inPerson)
    }

    /// Changed in 2.9: three seconds of sound in an hour used to be a call. One
    /// played video in a meeting room was enough, and down the call path the
    /// microphone is the whole room — everyone in it got your name, and the
    /// loudest of them was learned as your voice. A call is now a share of the
    /// recording as well as a number of seconds.
    func testSomethingPlayedInTheRoomDoesNotMakeACall() {
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 1.5, of: 3_600), hasMic: true), .inPerson)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 3, of: 3_600), hasMic: true), .inPerson)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 120, of: 3_600), hasMic: true), .inPerson,
                       "a two-minute video in an hour is still a meeting in the room")
    }

    func testTheOtherSideOfACallSpeaksForEnoughOfIt() {
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 600, of: 3_600), hasMic: true), .call)
        // The floor still holds for a short recording, where a share alone is tiny.
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 2, of: 30), hasMic: true), .inPerson)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 12, of: 30), hasMic: true), .call)
    }

    func testQuietNoiseIsNotSound() {
        let hiss = [UInt8](repeating: SpeakerRoute.audibleLevel - 1, count: 10_000)
        XCTAssertEqual(SpeakerRoute.audibleSeconds(hiss), 0)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: hiss, hasMic: true), .inPerson)
    }

    func testNoTracksMeansNobodyToTellApart() {
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: nil, hasMic: false), .nobody)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels(sound: 0, of: 60), hasMic: false), .nobody)
    }

    /// The system track of a broken capture is loud for the whole meeting and
    /// transcribes to almost nothing. The words are on the microphone, so that
    /// is the track to split, and the system track's lines are not kept.
    func testALoudTrackThatDoesNotTranscribeIsOneMicrophone() {
        let levels = levels(sound: 300, of: 344)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: levels, hasMic: true), .call,
                       "without a transcript the waveform still decides")
        let missed = SpeakerRoute.decision(systemLevels: levels, hasMic: true, systemSpeechSeconds: 30)
        XCTAssertEqual(missed.route, .inPerson)
        XCTAssertTrue(missed.discardSystemLines)
        let heard = SpeakerRoute.decision(systemLevels: levels, hasMic: true, systemSpeechSeconds: 200)
        XCTAssertEqual(heard.route, .call)
        XCTAssertFalse(heard.discardSystemLines)
        XCTAssertFalse(SpeakerRoute.holdsSpeech(audible: 300, speech: 30))
        XCTAssertTrue(SpeakerRoute.holdsSpeech(audible: 300, speech: 200))
    }

    /// Levels that would not read used to force the call path, because guessing
    /// "silent" diarized a real call's microphone. A transcript with nothing in
    /// it is not a guess: that microphone did not capture the conversation.
    func testAnUnreadableTrackWithNoSpeechIsOneMicrophone() {
        let empty = SpeakerRoute.decision(systemLevels: nil, hasMic: true, systemUnreadable: true,
                                          systemSpeechSeconds: 0)
        XCTAssertEqual(empty.route, .inPerson)
        XCTAssertTrue(empty.discardSystemLines)
        let spoken = SpeakerRoute.decision(systemLevels: nil, hasMic: true, systemUnreadable: true,
                                           systemSpeechSeconds: 40)
        XCTAssertEqual(spoken.route, .call)
        XCTAssertFalse(spoken.discardSystemLines)
        XCTAssertEqual(SpeakerRoute.choose(systemLevels: nil, hasMic: true, systemUnreadable: true), .call)
    }

    /// The laptop's one microphone has everyone in the room on it, including
    /// during a call. The far side stays a call; the microphone is diarized too.
    /// A headset call is not that microphone, and stays one person.
    func testTheLaptopsOneMicrophoneIsDiarizedEvenOnACall() {
        let call = levels(sound: 600, of: 1_800)
        let room = SpeakerRoute.decision(systemLevels: call, hasMic: true, systemSpeechSeconds: 500,
                                         soloMicrophone: true)
        XCTAssertEqual(room.route, .call)
        XCTAssertFalse(room.discardSystemLines)
        XCTAssertTrue(room.diarizeMicrophone)

        let headset = SpeakerRoute.decision(systemLevels: call, hasMic: true, systemSpeechSeconds: 500,
                                            soloMicrophone: false)
        XCTAssertEqual(headset.route, .call)
        XCTAssertFalse(headset.diarizeMicrophone)
    }

    func testTheLaptopsOneMicrophoneWithNoOtherSideIsInPerson() {
        let quiet = levels(sound: 0, of: 3_600)
        let choice = SpeakerRoute.decision(systemLevels: quiet, hasMic: true, soloMicrophone: true)
        XCTAssertEqual(choice.route, .inPerson)
        XCTAssertTrue(choice.diarizeMicrophone)
        XCTAssertFalse(SpeakerRoute.removesEcho(soloMicrophone: true, systemLevels: quiet),
                       "a chime is not the other side, and subtracting it would take the room out of the only mic")
        XCTAssertTrue(SpeakerRoute.removesEcho(soloMicrophone: true, systemLevels: levels(sound: 600, of: 1_800)))
        XCTAssertTrue(SpeakerRoute.removesEcho(soloMicrophone: false, systemLevels: quiet))
    }

    /// Reading the input device is what decides the flag. It has to work on a
    /// machine with no microphone as well as on a laptop.
    func testTheInputDeviceCanBeRead() {
        _ = InputDevices.isSolo
    }
}
