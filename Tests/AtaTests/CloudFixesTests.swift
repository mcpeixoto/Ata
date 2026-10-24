@testable import Ata
import XCTest

/// Two devices sharing the library in iCloud, where each can change what the other
/// is about to write: copies brought up to date, notes, transcripts kept in versions/,
/// claims, which device made a meeting, and voices. Everything happens in temporary
/// folders; nothing here talks to iCloud.
final class CloudFixesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    private let fm = FileManager.default
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FilesTests.root.appendingPathComponent("cloud-fixes-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CloudLibrary.use(.local)
        try? fm.removeItem(at: scratch)
    }

    // MARK: Helpers

    private let mac = DeviceRef(id: "mac-under-test", name: "Mac")
    private let phone = DeviceRef(id: "phone-under-test", name: "iPhone")

    private struct Folders {
        let local: URL
        let cloud: URL
        let migration: CloudMigration
    }

    private func folders(_ meetings: [String], device: DeviceRef) throws -> Folders {
        let local = scratch.appendingPathComponent("Local Meetings", isDirectory: true)
        let cloud = scratch.appendingPathComponent("Documents/Meetings", isDirectory: true)
        for name in meetings { try makeMeeting(name, in: local) }
        let migration = CloudMigration(source: local, destination: cloud,
                                       ledgerURL: scratch.appendingPathComponent("support/icloud-copy.json"),
                                       device: device)
        return Folders(local: local, cloud: cloud, migration: migration)
    }

    /// A meeting as Ata before 2.6 left it: its meeting.json names no device.
    private func makeMeeting(_ name: String, in parent: URL) throws {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeMeta(meeting(name, duration: 60), to: folder)
        try Data((0..<200_000).map { UInt8(($0 * 7 + name.count) & 0xFF) }).write(to: folder.appendingPathComponent("mic.wav"))
        try Data("Notes for \(name)".utf8).write(to: folder.appendingPathComponent("notes.md"))
    }

    private func meeting(_ id: String, duration: Double) -> Meeting {
        Meeting(id: id, startedAt: Date(timeIntervalSince1970: 1_767_600_000), endedAt: nil, duration: duration,
                app: "Zoom", status: .done, error: nil)
    }

    private func writeMeta(_ m: Meeting, to folder: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(m).write(to: folder.appendingPathComponent("meeting.json"))
    }

    private func readMeta(in folder: URL) throws -> Meeting {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ text: String, to url: URL, modified seconds: Double) throws {
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    // MARK: Turning iCloud on again (A)

    func testAFileTheOtherDeviceChangedIsKeptWhenThisOnesIsNewer() throws {
        let f = try folders(["A"], device: mac)
        _ = f.migration.run()
        // iCloud was off here; meanwhile the iPhone changed the notes in iCloud, earlier.
        try write("The iPhone's notes", to: f.cloud.appendingPathComponent("A/notes.md"), modified: 1_700_000_000)
        try write("The Mac's notes", to: f.local.appendingPathComponent("A/notes.md"), modified: 1_700_000_500)

        let outcome = f.migration.run()
        XCTAssertEqual(outcome.updated, ["A"])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(try text(f.cloud.appendingPathComponent("A/notes.md")), "The Mac's notes", "the newer keeps the name")
        XCTAssertEqual(try text(f.cloud.appendingPathComponent("A/notes (other device).md")), "The iPhone's notes",
                       "the other device's notes are kept beside it")
        XCTAssertTrue(f.migration.isComplete)

        // Nothing changed since: nothing is copied or put aside again.
        let again = f.migration.run()
        XCTAssertTrue(again.updated.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: f.cloud.appendingPathComponent("A/notes (other device 2).md").path))
    }

    func testAFileTheOtherDeviceChangedLaterKeepsItsName() throws {
        let f = try folders(["A"], device: mac)
        _ = f.migration.run()
        try write("The iPhone's notes", to: f.cloud.appendingPathComponent("A/notes.md"), modified: 1_700_000_900)
        try write("The Mac's notes", to: f.local.appendingPathComponent("A/notes.md"), modified: 1_700_000_500)

        let outcome = f.migration.run()
        XCTAssertEqual(outcome.updated, ["A"])
        XCTAssertEqual(try text(f.cloud.appendingPathComponent("A/notes.md")), "The iPhone's notes",
                       "never replaced by an older version")
        XCTAssertEqual(try text(f.cloud.appendingPathComponent("A/notes (other device).md")), "The Mac's notes")
        XCTAssertEqual(try text(f.local.appendingPathComponent("A/notes.md")), "The Mac's notes", "the original stays")
        XCTAssertTrue(f.migration.isComplete)
    }

    func testAFileOnlyThisDeviceChangedIsSimplyReplaced() throws {
        let f = try folders(["A"], device: mac)
        _ = f.migration.run()
        try Data("A second thought".utf8).write(to: f.local.appendingPathComponent("A/notes.md"))

        XCTAssertEqual(f.migration.run().updated, ["A"])
        XCTAssertEqual(try text(f.cloud.appendingPathComponent("A/notes.md")), "A second thought")
        let names = try fm.contentsOfDirectory(atPath: f.cloud.appendingPathComponent("A").path)
        XCTAssertFalse(names.contains { $0.contains("other device") }, "nothing to keep beside it")
    }

    // MARK: Notes in an open meeting (B)

    func testNotesChangedElsewhereAreShownOrKeptBoth() {
        // notes.md as last saved: nothing to do, typed or not.
        XCTAssertEqual(NotesRefresh.decide(buffer: "mine", saved: "mine", disk: "mine"), .keep)
        XCTAssertEqual(NotesRefresh.decide(buffer: "mine, typing", saved: "mine", disk: "mine"), .keep)
        // Nothing typed here: the other device's notes are shown.
        XCTAssertEqual(NotesRefresh.decide(buffer: "mine", saved: "mine", disk: "theirs"), .load)
        XCTAssertEqual(NotesRefresh.decide(buffer: "mine", saved: "mine", disk: ""), .load, "cleared there")
        // Typed on both: neither is lost.
        XCTAssertEqual(NotesRefresh.decide(buffer: "mine, typing", saved: "mine", disk: "theirs"), .keepBoth)
        // Both ended up the same.
        XCTAssertEqual(NotesRefresh.decide(buffer: "same", saved: "old", disk: "same"), .keep)
    }

    // MARK: Transcribing again (C)

    func testATranscriptStillInICloudIsNeverWrittenOver() throws {
        let id = "2026-10-24 10.00.00 Placeholder \(UUID().uuidString.prefix(4))"
        let dir = Paths.meetingsDir.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let m = meeting(id, duration: 60)
        // On iPhone, a transcript iCloud hasn't downloaded is only ".transcript.md.icloud".
        let placeholder = CloudFiles.placeholderURL(for: m.transcriptURL)
        try Data("placeholder".utf8).write(to: placeholder)
        XCTAssertNil(m.existingTranscriptURL)

        XCTAssertThrowsError(try Transcriber.archivePrevious(of: m), "a transcript in iCloud is still a transcript") {
            XCTAssertEqual($0 as? CloudFiles.Failure, .transcriptNotDownloaded)
        }
        XCTAssertTrue(fm.fileExists(atPath: placeholder.path), "left as it was")
        XCTAssertFalse(fm.fileExists(atPath: m.transcriptURL.path), "nothing written in its place")
    }

    // MARK: Claims (D)

    func testOnlyTheDeviceStillHoldingTheClaimFinishes() {
        var running = meeting("claimed", duration: 60)
        running.status = .transcribing
        running.claim = Claim(device: mac, at: Date())
        XCTAssertTrue(running.isClaimed(by: mac))
        XCTAssertFalse(running.isClaimed(by: phone))
        for status in [Meeting.Status.done, .failed, .pending] {
            XCTAssertTrue(Meeting.mayFinish(status, over: running, by: mac), "\(status)")
        }

        // The iPhone took it over while the Mac slept.
        var takenOver = running
        takenOver.claim = Claim(device: phone, at: Date())
        for status in [Meeting.Status.done, .failed, .pending] {
            XCTAssertFalse(Meeting.mayFinish(status, over: takenOver, by: mac), "\(status)")
        }

        // The iPhone finished it: a late failure or a second transcript never replaces it.
        var finished = running
        finished.status = .done
        finished.claim = nil
        XCTAssertFalse(Meeting.mayFinish(.failed, over: finished, by: mac))
        XCTAssertFalse(Meeting.mayFinish(.done, over: finished, by: mac))
        var doneButClaimed = running
        doneButClaimed.status = .done
        XCTAssertFalse(Meeting.mayFinish(.failed, over: doneButClaimed, by: mac), ".failed never over .done")

        // Deleted meanwhile: not brought back.
        XCTAssertFalse(Meeting.mayFinish(.done, over: nil, by: mac))
        // meeting.json still in iCloud: nothing to tell by.
        let stub = Library.placeholder(id: "2026-10-24 10.00.00", in: scratch)
        XCTAssertTrue(Meeting.mayFinish(.done, over: stub, by: mac))
    }

    // MARK: Which device made it (E)

    func testCopyingIntoICloudSaysWhichDeviceMadeAnOlderMeeting() throws {
        let name = "2026-01-05 09.00.00 Zoom"
        let f = try folders([name], device: mac)
        XCTAssertEqual(f.migration.run().copied, [name])

        let copy = f.cloud.appendingPathComponent(name, isDirectory: true)
        XCTAssertEqual(try readMeta(in: copy).origin, mac, "the copy names the device that copied it")
        XCTAssertNil(try readMeta(in: f.local.appendingPathComponent(name)).origin, "the original is untouched")
        XCTAssertEqual(try readMeta(in: copy).duration, 60)
        XCTAssertTrue(f.migration.isComplete)
        let again = f.migration.run()
        XCTAssertTrue(again.copied.isEmpty && again.updated.isEmpty, "not seen as changed")

        // Changed here since: brought up to date, still naming its device.
        try writeMeta(meeting(name, duration: 120), to: f.local.appendingPathComponent(name))
        XCTAssertEqual(f.migration.run().updated, [name])
        XCTAssertEqual(try readMeta(in: copy).duration, 120)
        XCTAssertEqual(try readMeta(in: copy).origin, mac)
        XCTAssertFalse(fm.fileExists(atPath: copy.appendingPathComponent("meeting (other device).json").path))

        // The ledger lost: the stamped copy is still recognised as this one, not copied twice.
        try fm.removeItem(at: f.migration.ledgerURL)
        XCTAssertEqual(f.migration.run().copied, [name])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.cloud.path), [name])
    }

    func testAMeetingCopiedBeforeCopiesSaidSoIsStampedOnTheNextRun() throws {
        let name = "2026-01-06 09.00.00 Zoom"
        let f = try folders([name], device: mac)
        _ = f.migration.run()
        let copy = f.cloud.appendingPathComponent(name, isDirectory: true)
        // As Ata 2.7.0 copied it: no device.
        try writeMeta(meeting(name, duration: 60), to: copy)
        XCTAssertNil(try readMeta(in: copy).origin)

        _ = f.migration.run()
        XCTAssertEqual(try readMeta(in: copy).origin, mac)
        XCTAssertTrue(f.migration.isComplete)

        // That write was this device's own: a later change here simply replaces it.
        try writeMeta(meeting(name, duration: 90), to: f.local.appendingPathComponent(name))
        XCTAssertEqual(f.migration.run().updated, [name])
        XCTAssertEqual(try readMeta(in: copy).duration, 90)
        XCTAssertFalse(fm.fileExists(atPath: copy.appendingPathComponent("meeting (other device).json").path))
    }

    func testAMeetingNamingNoDeviceIsThisOnesOnlyOffICloud() {
        let old = meeting("2025-03-01 10.00.00", duration: 60)
        XCTAssertNil(old.origin)
        XCTAssertTrue(old.isMine, "on one device, a meeting from before 2.6 is this one's")

        CloudLibrary.use(.cloud(scratch.appendingPathComponent("Documents", isDirectory: true)))
        XCTAssertFalse(old.isMine, "in iCloud it may be the other device's")
        XCTAssertFalse(old.belongs(to: Device.current))
        var stamped = old
        stamped.origin = Device.current
        XCTAssertTrue(stamped.isMine)
        stamped.origin = phone
        XCTAssertFalse(stamped.isMine)
    }

    // MARK: Files still in iCloud (F)

    func testFilesStillInICloudAreAskedForNotRead() throws {
        let waiting = scratch.appendingPathComponent("transcript.json")
        try Data().write(to: CloudFiles.placeholderURL(for: waiting))
        let here = scratch.appendingPathComponent("notes.md")
        try Data("notes".utf8).write(to: here)
        let absent = scratch.appendingPathComponent("speakers.json")
        XCTAssertEqual(CloudFiles.readable(waiting), waiting, "on one device nothing is in iCloud")

        CloudLibrary.use(.cloud(scratch.appendingPathComponent("Documents", isDirectory: true)))
        XCTAssertNil(CloudFiles.readable(waiting))
        XCTAssertNil(StoredTranscript.load(from: waiting))
        XCTAssertEqual(CloudFiles.readable(here), here)
        XCTAssertEqual(CloudFiles.readable(absent), absent, "not there at all: nothing to wait for")

        // A voice not downloaded yet is known to be on its way, and never written over.
        let voices = scratch.appendingPathComponent("Voices", isDirectory: true)
        try fm.createDirectory(at: voices, withIntermediateDirectories: true)
        let id = UUID()
        try Data().write(to: voices.appendingPathComponent(".\(id.uuidString).json.icloud"))
        let library = VoiceLibrary(directory: voices)
        XCTAssertTrue(library.voices.isEmpty)
        XCTAssertEqual(library.downloading, [id])
        XCTAssertEqual(library.unreadable.map(\.lastPathComponent), ["\(id.uuidString).json"])
    }

    // MARK: Voices (G)

    private func voice(_ id: UUID, name: String? = nil, centroid: [Float], observations: Int,
                       meetings: [String], lastSeen: Double) -> Voice {
        Voice(id: id, name: name, centroid: centroid, observations: observations, meetingIDs: meetings, sample: nil,
              firstSeen: Date(timeIntervalSince1970: 1_800_000_000), lastSeen: Date(timeIntervalSince1970: lastSeen),
              number: 3, model: VoiceLibrary.model)
    }

    func testANameGivenOnOneDeviceSurvivesAFingerprintLearnedOnTheOther() throws {
        let id = UUID()
        let base = voice(id, centroid: [1, 0, 0], observations: 2, meetings: ["m1", "m2"], lastSeen: 1_800_000_100)
        // The Mac named it…
        var named = base
        named.name = "Rita"
        named.edited = Date(timeIntervalSince1970: 1_800_000_500)
        // …while the iPhone, later, heard it in a third meeting.
        var learned = voice(id, centroid: VoiceLibrary.normalised([1, 1, 0]), observations: 3,
                            meetings: ["m1", "m2", "m3"], lastSeen: 1_800_000_900)
        learned.sample = "\(id.uuidString).m4a"

        let a = VoiceLibrary.Version(voice: named, modified: Date(timeIntervalSince1970: 1_800_000_500))
        let b = VoiceLibrary.Version(voice: learned, modified: Date(timeIntervalSince1970: 1_800_000_900))
        let merged = try XCTUnwrap(VoiceLibrary.merge(versions: [a, b]))
        XCTAssertEqual(merged.name, "Rita")
        XCTAssertEqual(merged.edited, named.edited)
        XCTAssertEqual(merged.meetingIDs, ["m1", "m2", "m3"])
        XCTAssertEqual(merged.observations, 3, "the versions share their history: not 5")
        XCTAssertEqual(merged.sample, learned.sample)
        XCTAssertEqual(merged.lastSeen, learned.lastSeen)
        XCTAssertEqual(merged.number, 3)
        // Between the two fingerprints, and still a unit vector.
        XCTAssertGreaterThan(VoiceLibrary.cosine(merged.centroid, named.centroid), 0.7)
        XCTAssertGreaterThan(VoiceLibrary.cosine(merged.centroid, learned.centroid), 0.9)
        XCTAssertEqual(merged.centroid.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.0001)
        // Both devices settle it the same way.
        XCTAssertEqual(VoiceLibrary.merge(versions: [b, a]), merged)
    }

    func testTheLaterEditWinsAndAnOlderNameIsKept() throws {
        let id = UUID()
        var first = voice(id, name: "Rita", centroid: [1, 0, 0], observations: 2, meetings: ["m1"], lastSeen: 1_800_000_100)
        first.edited = Date(timeIntervalSince1970: 1_800_000_100)
        var renamed = first
        renamed.name = "Rita Lopes"
        renamed.edited = Date(timeIntervalSince1970: 1_800_000_300)
        // The rename was saved as the older version of the file: the edit's own time decides.
        let merged = VoiceLibrary.merge(versions: [
            .init(voice: first, modified: Date(timeIntervalSince1970: 1_800_000_900)),
            .init(voice: renamed, modified: Date(timeIntervalSince1970: 1_800_000_300)),
        ])
        XCTAssertEqual(merged?.name, "Rita Lopes")

        // Named by an Ata that didn't record edits: the name there is wins over none.
        let old = voice(id, name: "Ana", centroid: [1, 0, 0], observations: 2, meetings: ["m1"], lastSeen: 1_800_000_100)
        let newer = voice(id, centroid: [1, 0, 0], observations: 3, meetings: ["m1", "m2"], lastSeen: 1_800_000_200)
        let kept = VoiceLibrary.merge(versions: [
            .init(voice: old, modified: Date(timeIntervalSince1970: 1_800_000_100)),
            .init(voice: newer, modified: Date(timeIntervalSince1970: 1_800_000_200)),
        ])
        XCTAssertEqual(kept?.name, "Ana")
        XCTAssertEqual(kept?.meetingIDs, ["m1", "m2"])

        // Two different voices are never one.
        let stranger = voice(UUID(), centroid: [0, 1, 0], observations: 1, meetings: ["m9"], lastSeen: 1_800_000_000)
        XCTAssertNil(VoiceLibrary.merge(versions: [.init(voice: old, modified: nil), .init(voice: stranger, modified: nil)]))
    }

    func testEditingAVoiceByHandIsDated() throws {
        let library = VoiceLibrary(directory: scratch.appendingPathComponent("voices", isDirectory: true))
        let speaker = MeetingSpeaker(label: "S1", embedding: [1, 0, 0], seconds: 5, voiceID: nil)
        let id = try XCTUnwrap(library.assign([speaker], meetingID: "m1").first?.voiceID)
        XCTAssertNil(library.voice(id)?.edited, "learning is not an edit")
        library.rename(id, to: "Rita")
        let named = try XCTUnwrap(library.voice(id)?.edited)
        library.setExcluded(id, true)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(library.voice(id)?.edited), named)
    }
}
