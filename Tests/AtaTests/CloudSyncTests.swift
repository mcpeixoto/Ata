@testable import Ata
import XCTest

/// iCloud sync, apart from iCloud itself: where the library is, meetings that
/// haven't downloaded yet, conflicts, settings, and the copy into the container.
/// Everything happens in temporary folders; nothing here talks to iCloud.
final class CloudSyncTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    private let fm = FileManager.default
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FilesTests.root.appendingPathComponent("cloud-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CloudLibrary.use(.local)
        try? fm.removeItem(at: scratch)
    }

    // MARK: Where the library is

    func testTheDevelopmentFoldersAndTheSettingDecideWhereTheLibraryIs() {
        let local = LibraryLocation(meetings: URL(fileURLWithPath: "/tmp/m", isDirectory: true),
                                    voices: URL(fileURLWithPath: "/tmp/v", isDirectory: true), inCloud: false)
        let docs = URL(fileURLWithPath: "/tmp/container/Documents", isDirectory: true)

        XCTAssertEqual(LibraryLocation.resolve(overridden: true, syncOn: true, cloudDocuments: docs, local: local), local)
        XCTAssertEqual(LibraryLocation.resolve(overridden: false, syncOn: false, cloudDocuments: docs, local: local), local)
        // On, but iCloud isn't there: this device's folder, never a folder that doesn't exist.
        XCTAssertEqual(LibraryLocation.resolve(overridden: false, syncOn: true, cloudDocuments: nil, local: local), local)

        let cloud = LibraryLocation.resolve(overridden: false, syncOn: true, cloudDocuments: docs, local: local)
        XCTAssertTrue(cloud.inCloud)
        XCTAssertEqual(cloud.meetings.path, "/tmp/container/Documents/Meetings")
        XCTAssertEqual(cloud.voices.path, "/tmp/container/Documents/Voices")
    }

    func testThisRunUsesTheTemporaryFoldersWhateverTheSetting() {
        XCTAssertTrue(Paths.overridden)
        XCTAssertFalse(CloudLibrary.launchLocation().inCloud)
        XCTAssertFalse(CloudLibrary.isActive)
        XCTAssertEqual(Paths.meetingsDir.path, FilesTests.root.path)
        XCTAssertEqual(Paths.voicesDir, Paths.localVoicesDir)
        XCTAssertTrue(Paths.voicesDir.path.hasPrefix(FilesTests.root.path))
    }

    func testTheVoiceLibraryFollowsTheLibrary() throws {
        let cloud = LibraryLocation.cloud(scratch.appendingPathComponent("Documents", isDirectory: true))
        CloudLibrary.use(cloud)
        XCTAssertEqual(VoiceLibrary().directory, cloud.voices)
        CloudLibrary.use(.local)
        XCTAssertEqual(VoiceLibrary().directory, Paths.localVoicesDir)
    }

    // MARK: Not downloaded yet

    func testAMeetingStillInICloudIsListedAsAStub() throws {
        let cloud = LibraryLocation.cloud(scratch.appendingPathComponent("Documents", isDirectory: true))
        let id = "2026-10-23 14.02.05 Zoom"
        let folder = cloud.meetings.appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".meeting.json.icloud"))
        try Data().write(to: folder.appendingPathComponent(".mic.wav.icloud"))
        CloudLibrary.use(cloud)

        let stub = try XCTUnwrap(Library.loadAll().first { $0.id == id }, "a meeting in iCloud must not vanish")
        XCTAssertTrue(stub.isPlaceholder)
        XCTAssertEqual(stub.app, "Zoom")
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let expected = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 14, minute: 2, second: 5))
        XCTAssertEqual(stub.startedAt, expected)
        // Its device is unknown until meeting.json arrives: never this one's to recover,
        // prune or transcribe.
        XCTAssertFalse(stub.isMine)
        XCTAssertNil(stub.recovered())
        XCTAssertFalse(stub.awaitsTranscript())
        // Its audio is in iCloud: there, to be downloaded when it's needed.
        XCTAssertTrue(stub.hasAudio)
        XCTAssertEqual(stub.micAudioURL?.lastPathComponent, "mic.wav")

        // Saving the stand-in would replace the real meeting.json.
        Library.save(stub)
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent("meeting.json").path))
    }

    func testAMeetingThatHasDownloadedIsReadAsItIs() throws {
        let cloud = LibraryLocation.cloud(scratch.appendingPathComponent("Documents", isDirectory: true))
        CloudLibrary.use(cloud)
        var m = Meeting(id: "2026-10-23 09.00.00", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        endedAt: nil, duration: 60, app: "Teams", status: .done, error: nil)
        m.origin = DeviceRef(id: "phone", name: "iPhone")
        Library.save(m)  // a coordinated write, with the library in iCloud

        let loaded = try XCTUnwrap(Library.load(m.id))
        XCTAssertFalse(loaded.isPlaceholder)
        XCTAssertEqual(loaded.app, "Teams")
        XCTAssertEqual(loaded.origin?.name, "iPhone")
        let json = try String(contentsOf: m.metaURL, encoding: .utf8)
        XCTAssertFalse(json.contains("cloudPlaceholder"), "the marker is never written")
    }

    func testFolderNamesGiveTheDateAndTheApp() {
        XCTAssertEqual(Library.folderName("2026-10-23 14.02.05 Google Meet").app, "Google Meet")
        XCTAssertNotNil(Library.folderName("2026-10-23 14.02.05").date)
        XCTAssertNil(Library.folderName("2026-10-23 14.02.05").app)
        XCTAssertNil(Library.folderName("Imported memo").date)
        XCTAssertNil(Library.folderName("Imported memo").app)
    }

    func testFilesStillInICloudAreTold() throws {
        let file = scratch.appendingPathComponent("mic.wav")
        XCTAssertEqual(CloudFiles.placeholderURL(for: file).lastPathComponent, ".mic.wav.icloud")
        XCTAssertEqual(CloudFiles.state(of: file), .missing)
        try Data().write(to: CloudFiles.placeholderURL(for: file))
        XCTAssertEqual(CloudFiles.state(of: file), .inCloud)
        XCTAssertTrue(CloudFiles.isPlaceholder(file))
        XCTAssertFalse(CloudFiles.areLocal([file]))
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(CloudFiles.state(of: file), .local)
        XCTAssertFalse(CloudFiles.isPlaceholder(file))
        XCTAssertTrue(CloudFiles.areLocal([file]))
    }

    func testOnlyTheSmallFilesAreFetchedAhead() {
        let meeting = URL(fileURLWithPath: "/c/Documents/Meetings/2026-10-23 14.02.05", isDirectory: true)
        for name in ["meeting.json", "transcript.json", "transcript.md", "notes.md", "speakers.json",
                     "waveform.bin", "notes (other device).md"] {
            XCTAssertTrue(CloudFiles.wantsEagerDownload(meeting.appendingPathComponent(name)), name)
        }
        for name in ["mic.wav", "system.m4a", "meeting.mp3", "versions/2026-10-23 15.00.00/transcript.md"] {
            XCTAssertFalse(CloudFiles.wantsEagerDownload(meeting.appendingPathComponent(name)), name)
        }
        let voices = URL(fileURLWithPath: "/c/Documents/Voices", isDirectory: true)
        XCTAssertTrue(CloudFiles.wantsEagerDownload(voices.appendingPathComponent("\(UUID().uuidString).json")))
        XCTAssertTrue(CloudFiles.wantsEagerDownload(voices.appendingPathComponent("\(UUID().uuidString).m4a")))
    }

    // MARK: Conflicts

    private let earlier = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    func testNotesInConflictKeepEveryVersion() {
        // The other device's notes are newer: they become notes.md, and this device's are kept beside them.
        let plan = Conflicts.plan(fileName: "notes.md", modified: [earlier, later], taken: ["notes.md"])
        XCTAssertEqual(plan.winner, 1)
        XCTAssertEqual(plan.keptAside, [0: "notes (other device).md"])

        // Names already in the folder are never written over.
        let three = Conflicts.plan(fileName: "notes.md", modified: [later, earlier, nil],
                                   taken: ["notes.md", "notes (other device).md"])
        XCTAssertEqual(three.winner, 0)
        XCTAssertEqual(three.keptAside, [1: "notes (other device 2).md", 2: "notes (other device 3).md"])
    }

    func testFilesAtaWritesKeepTheNewest() {
        for name in ["meeting.json", "transcript.json", "transcript.md", "speakers.json", "waveform.bin",
                     "\(UUID().uuidString).json"] {
            let plan = Conflicts.plan(fileName: name, modified: [earlier, later, nil], taken: [name])
            XCTAssertEqual(plan.winner, 1, name)
            XCTAssertTrue(plan.keptAside.isEmpty, name)
            XCTAssertEqual(Conflicts.rule(for: name), .newest)
        }
        // A tie keeps this device's version.
        XCTAssertEqual(Conflicts.plan(fileName: "meeting.json", modified: [earlier, earlier], taken: []).winner, 0)
        XCTAssertEqual(Conflicts.rule(for: "notes.md"), .keepBoth)
    }

    func testAsideNames() {
        XCTAssertEqual(Conflicts.asideName(for: "notes.md", number: 1), "notes (other device).md")
        XCTAssertEqual(Conflicts.asideName(for: "notes.md", number: 4), "notes (other device 4).md")
        XCTAssertEqual(Conflicts.asideName(for: "README", number: 1), "README (other device)")
    }

    // MARK: Settings

    func testTheLatestChangeToASettingWins() {
        typealias Stamped = SettingsMerge.Stamped
        let ana = Stamped(value: .string("Ana"), at: Date(timeIntervalSince1970: 100))
        let bea = Stamped(value: .string("Bea"), at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(SettingsMerge.decide(local: nil, remote: nil), .keep)
        XCTAssertEqual(SettingsMerge.decide(local: ana, remote: nil), .push)
        // Never set on this device: a default never overrides a choice made on the other.
        XCTAssertEqual(SettingsMerge.decide(local: nil, remote: bea), .pull)
        XCTAssertEqual(SettingsMerge.decide(local: ana, remote: bea), .pull)
        XCTAssertEqual(SettingsMerge.decide(local: bea, remote: ana), .push)
        let anaAgain = Stamped(value: .string("Ana"), at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(SettingsMerge.decide(local: ana, remote: anaAgain), .keep)
    }

    func testATieEndsWithTheSameValueOnBothDevices() {
        let on = SettingsMerge.Stamped(value: .bool(true), at: .distantPast)
        let off = SettingsMerge.Stamped(value: .bool(false), at: .distantPast)
        func result(local: SettingsMerge.Stamped, remote: SettingsMerge.Stamped) -> SettingsMerge.Value {
            SettingsMerge.decide(local: local, remote: remote) == .pull ? remote.value : local.value
        }
        XCTAssertEqual(result(local: on, remote: off), result(local: off, remote: on))
    }

    // MARK: Copying into iCloud

    private struct Folders {
        let local: URL
        let cloud: URL
        let migration: CloudMigration
    }

    private func folders(_ meetings: [String]) throws -> Folders {
        let local = scratch.appendingPathComponent("Local Meetings", isDirectory: true)
        let cloud = scratch.appendingPathComponent("Documents/Meetings", isDirectory: true)
        for name in meetings { try makeMeeting(name, in: local) }
        let migration = CloudMigration(source: local, destination: cloud,
                                       ledgerURL: scratch.appendingPathComponent("support/icloud-copy.json"))
        return Folders(local: local, cloud: cloud, migration: migration)
    }

    private func makeMeeting(_ name: String, in parent: URL) throws {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        let versions = folder.appendingPathComponent("versions/2026-10-01 10.00.00", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(name)"}"#.utf8).write(to: folder.appendingPathComponent("meeting.json"))
        try Data((0..<300_000).map { UInt8(($0 * 31 + name.count) & 0xFF) }).write(to: folder.appendingPathComponent("mic.wav"))
        try Data("Notes for \(name)".utf8).write(to: folder.appendingPathComponent("notes.md"))
        try Data("An earlier transcript".utf8).write(to: versions.appendingPathComponent("transcript.md"))
    }

    private func names(in dir: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func testEveryMeetingIsCopiedAndCheckedAndTheOriginalsStay() throws {
        let f = try folders(["A", "B", "C"])
        XCTAssertFalse(f.migration.isComplete)

        let outcome = f.migration.run()
        XCTAssertEqual(outcome.copied.sorted(), ["A", "B", "C"])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(outcome.stopped)
        XCTAssertTrue(f.migration.isComplete)
        // Nothing half-copied is left visible or hidden.
        XCTAssertEqual(try names(in: f.cloud), ["A", "B", "C"])
        for name in ["A", "B", "C"] {
            XCTAssertTrue(CloudMigration.verified(f.cloud.appendingPathComponent(name),
                                                  against: f.local.appendingPathComponent(name)), name)
            XCTAssertTrue(fm.fileExists(atPath: f.local.appendingPathComponent("\(name)/mic.wav").path),
                          "the original stays")
        }
    }

    func testACopyWithOneWrongByteIsNotACopy() throws {
        let f = try folders(["A"])
        let copy = scratch.appendingPathComponent("copy of A", isDirectory: true)
        try fm.copyItem(at: f.local.appendingPathComponent("A"), to: copy)
        XCTAssertTrue(CloudMigration.verified(copy, against: f.local.appendingPathComponent("A")))

        var bytes = try Data(contentsOf: copy.appendingPathComponent("mic.wav"))
        bytes[1_000] ^= 0xFF  // same size, different audio
        try bytes.write(to: copy.appendingPathComponent("mic.wav"))
        XCTAssertTrue(Library.covers(copy, f.local.appendingPathComponent("A")), "sizes alone can't tell")
        XCTAssertFalse(CloudMigration.verified(copy, against: f.local.appendingPathComponent("A")))
    }

    func testACopyCutShortLeavesTheOriginalsAndTheNextRunCarriesOn() throws {
        let f = try folders(["A", "B", "C"])
        var asked = 0
        let first = f.migration.run(shouldContinue: {
            asked += 1
            return asked <= 1
        })
        XCTAssertTrue(first.stopped)
        XCTAssertEqual(first.copied, ["A"])
        XCTAssertFalse(f.migration.isComplete)
        XCTAssertEqual(try names(in: f.local), ["A", "B", "C"], "every original is still there")

        // A crash in the middle of copying B left half a hidden copy behind.
        let partial = f.cloud.appendingPathComponent(".B.partial", isDirectory: true)
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: partial.appendingPathComponent("mic.wav"))
        let copiedA = try fm.attributesOfItem(atPath: f.cloud.appendingPathComponent("A/mic.wav").path)[.modificationDate] as? Date

        let second = f.migration.run()
        XCTAssertEqual(second.copied.sorted(), ["B", "C"], "A is not copied again")
        XCTAssertTrue(f.migration.isComplete)
        XCTAssertEqual(try names(in: f.cloud), ["A", "B", "C"])
        XCTAssertTrue(CloudMigration.verified(f.cloud.appendingPathComponent("B"), against: f.local.appendingPathComponent("B")))
        let stillA = try fm.attributesOfItem(atPath: f.cloud.appendingPathComponent("A/mic.wav").path)[.modificationDate] as? Date
        XCTAssertEqual(copiedA, stillA)
    }

    func testAFolderCopiedBeforeTheLedgerWasWrittenIsRecognised() throws {
        let f = try folders(["A"])
        try fm.createDirectory(at: f.cloud, withIntermediateDirectories: true)
        try fm.copyItem(at: f.local.appendingPathComponent("A"), to: f.cloud.appendingPathComponent("A"))

        let outcome = f.migration.run()
        XCTAssertEqual(outcome.copied, ["A"])
        XCTAssertEqual(try names(in: f.cloud), ["A"], "no second copy beside it")
    }

    func testAnotherDevicesMeetingWithTheSameNameIsLeftAlone() throws {
        let f = try folders(["2026-10-23 14.02.05"])
        let theirs = f.cloud.appendingPathComponent("2026-10-23 14.02.05", isDirectory: true)
        try fm.createDirectory(at: theirs, withIntermediateDirectories: true)
        try Data("the iPhone's".utf8).write(to: theirs.appendingPathComponent("meeting.json"))

        let outcome = f.migration.run()
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(try names(in: f.cloud), ["2026-10-23 14.02.05", "2026-10-23 14.02.05 2"])
        XCTAssertEqual(try String(contentsOf: theirs.appendingPathComponent("meeting.json"), encoding: .utf8),
                       "the iPhone's")
        XCTAssertTrue(f.migration.isComplete)
    }

    func testAMeetingChangedAfterItsCopyIsBroughtUpToDate() throws {
        let f = try folders(["A", "B"])
        _ = f.migration.run()
        try Data("Notes for A, and a second thought".utf8)
            .write(to: f.local.appendingPathComponent("A/notes.md"))
        XCTAssertFalse(f.migration.isComplete)
        XCTAssertEqual(f.migration.pending(), ["A"])

        let outcome = f.migration.run()
        XCTAssertEqual(outcome.updated, ["A"])
        XCTAssertTrue(outcome.copied.isEmpty)
        XCTAssertEqual(try String(contentsOf: f.cloud.appendingPathComponent("A/notes.md"), encoding: .utf8),
                       "Notes for A, and a second thought")
        XCTAssertTrue(f.migration.isComplete)
    }

    func testAMeetingDeletedInICloudIsNotCopiedBack() throws {
        let f = try folders(["A", "B"])
        _ = f.migration.run()
        try fm.removeItem(at: f.cloud.appendingPathComponent("A"))

        XCTAssertTrue(f.migration.isComplete)
        let outcome = f.migration.run()
        XCTAssertTrue(outcome.copied.isEmpty)
        XCTAssertEqual(try names(in: f.cloud), ["B"])
    }

    func testOriginalsCanGoOnlyOnceTheirCopyIsUploadedAndUnchanged() throws {
        let f = try folders(["A", "B"])
        XCTAssertTrue(f.migration.removableOriginals(isUploaded: { _ in true }).isEmpty, "nothing copied yet")
        _ = f.migration.run()

        XCTAssertTrue(f.migration.removableOriginals(isUploaded: { _ in false }).isEmpty)
        XCTAssertEqual(f.migration.removableOriginals(isUploaded: { _ in true }), ["A", "B"])
        // A notes.md not uploaded yet keeps A.
        let notesOfA: (URL) -> Bool = {
            $0.lastPathComponent == "notes.md" && $0.deletingLastPathComponent().lastPathComponent == "A"
        }
        XCTAssertEqual(f.migration.removableOriginals(isUploaded: { !notesOfA($0) }), ["B"])
        // Changed since its copy: kept until the next copy.
        try Data("more".utf8).write(to: f.local.appendingPathComponent("B/notes.md"))
        XCTAssertEqual(f.migration.removableOriginals(isUploaded: { _ in true }), ["A"])
    }

    func testVoicesAreCopiedOnceAndNeverOverAVoiceAlreadyInICloud() throws {
        let local = scratch.appendingPathComponent("voices", isDirectory: true)
        let cloud = scratch.appendingPathComponent("Documents/Voices", isDirectory: true)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let mine = UUID().uuidString, both = UUID().uuidString
        try Data("mine".utf8).write(to: local.appendingPathComponent("\(mine).json"))
        try Data("sample".utf8).write(to: local.appendingPathComponent("\(mine).m4a"))
        try Data("this Mac's".utf8).write(to: local.appendingPathComponent("\(both).json"))
        try Data("already synced".utf8).write(to: cloud.appendingPathComponent("\(both).json"))
        let migration = CloudMigration(source: scratch.appendingPathComponent("none"), destination: scratch,
                                       ledgerURL: scratch.appendingPathComponent("support/icloud-copy.json"))

        XCTAssertTrue(migration.copyVoices(from: local, to: cloud).isEmpty)
        XCTAssertEqual(try String(contentsOf: cloud.appendingPathComponent("\(mine).json"), encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: cloud.appendingPathComponent("\(mine).m4a"), encoding: .utf8), "sample")
        XCTAssertEqual(try String(contentsOf: cloud.appendingPathComponent("\(both).json"), encoding: .utf8),
                       "already synced")
        XCTAssertTrue(fm.fileExists(atPath: local.appendingPathComponent("\(mine).json").path), "the original stays")

        // Forgotten on the other device: not brought back.
        try fm.removeItem(at: cloud.appendingPathComponent("\(mine).json"))
        XCTAssertTrue(migration.copyVoices(from: local, to: cloud).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: cloud.appendingPathComponent("\(mine).json").path))
    }
}
