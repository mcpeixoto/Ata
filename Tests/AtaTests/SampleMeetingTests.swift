@testable import Ata
import XCTest

/// The bundled example: written once into an empty library, left out of the
/// free minutes and out of iCloud, and not put back after it is deleted.
final class SampleMeetingTests: XCTestCase {
    private var scratch: URL!
    private let fm = FileManager.default

    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    override func setUpWithError() throws {
        scratch = FilesTests.root.appendingPathComponent("sample-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CloudLibrary.use(.local)
        try? fm.removeItem(at: scratch)
    }

    func testItInstallsOnceAndNotAgainAfterDeletion() throws {
        let defaults = UserDefaults(suiteName: "ata.sample.tests.\(UUID().uuidString)")!
        XCTAssertTrue(SampleMeeting.shouldInstall(meetingCount: 0, dismissed: false))
        XCTAssertFalse(SampleMeeting.shouldInstall(meetingCount: 3, dismissed: false))
        XCTAssertFalse(SampleMeeting.shouldInstall(meetingCount: 0, dismissed: true))

        XCTAssertTrue(try SampleMeeting.install(into: scratch, meetingCount: 0, defaults: defaults))
        let folder = scratch.appendingPathComponent(SampleMeeting.folderID, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(contentsOf: folder.appendingPathComponent("meeting.json")))
        XCTAssertEqual(meeting.isSample, true)
        XCTAssertEqual(meeting.bookmarks?.count, 1)
        XCTAssertGreaterThanOrEqual(meeting.duration ?? 0, 60)
        XCTAssertLessThanOrEqual(meeting.duration ?? 0, 90)
        let stored = try decoder.decode(StoredTranscript.self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
        XCTAssertFalse(stored.summary?.isEmpty ?? true)
        XCTAssertEqual(Set(stored.segments.map(\.speaker)), ["me", "S1"])
        let voices = try decoder.decode(MeetingVoices.self, from: Data(contentsOf: folder.appendingPathComponent("speakers.json")))
        XCTAssertEqual(voices.speakers.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))

        XCTAssertFalse(try SampleMeeting.install(into: scratch, meetingCount: 0, defaults: defaults),
                       "a second launch finds the example and leaves it")
        try fm.removeItem(at: folder)
        SampleMeeting.noteDeleted(meeting, defaults: defaults)
        XCTAssertFalse(try SampleMeeting.install(into: scratch, meetingCount: 0, defaults: defaults))
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
    }

    func testTheSampleIsNotCopiedIntoICloud() throws {
        let local = scratch.appendingPathComponent("local", isDirectory: true)
        let cloud = scratch.appendingPathComponent("cloud", isDirectory: true)
        let sample = local.appendingPathComponent(SampleMeeting.folderID, isDirectory: true)
        let real = local.appendingPathComponent("2026-01-01 10.00.00 Zoom", isDirectory: true)
        try fm.createDirectory(at: sample, withIntermediateDirectories: true)
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: real.appendingPathComponent("meeting.json"))
        let migration = CloudMigration(source: local, destination: cloud,
                                       ledgerURL: scratch.appendingPathComponent("ledger.json"))
        XCTAssertEqual(migration.pending(), ["2026-01-01 10.00.00 Zoom"])
        XCTAssertEqual(migration.run().copied, ["2026-01-01 10.00.00 Zoom"])
        XCTAssertFalse(fm.fileExists(atPath: cloud.appendingPathComponent(SampleMeeting.folderID).path))
        XCTAssertTrue(fm.fileExists(atPath: sample.path), "the original stays")
        XCTAssertFalse(migration.removableOriginals().contains(SampleMeeting.folderID))
    }

    func testTheSampleIsListedFromThisDeviceWhenTheLibraryIsInICloud() throws {
        let previous = CloudLibrary.location
        defer {
            CloudLibrary.use(previous)
            try? fm.removeItem(at: Paths.localMeetingsDir.appendingPathComponent(SampleMeeting.folderID))
        }
        let docs = scratch.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        CloudLibrary.use(.cloud(docs))
        _ = try SampleMeeting.write(into: Paths.localMeetingsDir)
        let cloudCopy = docs.appendingPathComponent("Meetings").appendingPathComponent(SampleMeeting.folderID)
        XCTAssertFalse(fm.fileExists(atPath: cloudCopy.path))
        XCTAssertEqual(Library.load(SampleMeeting.folderID)?.isSample, true)
        XCTAssertTrue(Library.loadAll().contains { $0.id == SampleMeeting.folderID })
    }
}
