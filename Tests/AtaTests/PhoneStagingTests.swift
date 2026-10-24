@testable import Ata
import XCTest

/// How the iPhone's recordings and every import leave staging: published into
/// the meetings folder when they stop, and what a crash leaves behind on the
/// next launch. The iPhone runs this shared code, so it is tested here.
final class PhoneStagingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    private let fm = FileManager.default

    private func wav(seconds: Double, at url: URL, headerBytes: UInt32? = nil) throws {
        let samples = Int(seconds * WavWriter.sampleRate)
        var data = WavWriter.header(dataBytes: headerBytes ?? UInt32(samples * 2))
        data.append(Data((0..<samples * 2).map { UInt8(($0 * 11) & 0xFF) }))
        try data.write(to: url)
    }

    private func le(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private func scratch(_ name: String) throws -> URL {
        let dir = FilesTests.root.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func isStaged(_ id: String) -> Bool {
        fm.fileExists(atPath: Device.stagingDir.appendingPathComponent(id).path)
    }

    private func label(_ prefix: String) -> String {
        "\(prefix) \(UUID().uuidString.prefix(6))"
    }

    // MARK: Publishing a recording

    func testAnIPhoneRecordingIsPublishedIntoTheMeetingsFolder() throws {
        let staged = try StagingFolder.create(app: label("Phone"))
        XCTAssertEqual(staged.folder.deletingLastPathComponent().path, Device.stagingDir.path)
        // Why the destination can't be `dir`: while staged, that is the staging folder itself.
        XCTAssertEqual(staged.meeting.dir.path, staged.folder.path)
        XCTAssertEqual(Library.load(staged.meeting.id)?.status, .recording, "recoverable from the start")

        try wav(seconds: 1, at: staged.folder.appendingPathComponent("mic.wav"))
        var m = staged.meeting
        m.status = .pending
        m.duration = 1
        m.bookmarks = [Bookmark(ms: 250)]
        let result = StagingFolder.publish(m)

        XCTAssertTrue(result.moved)
        XCTAssertEqual(result.meeting.id, m.id)
        XCTAssertFalse(isStaged(m.id), "nothing left in staging")
        XCTAssertEqual(result.meeting.dir.deletingLastPathComponent().path, Paths.meetingsDir.path)
        let saved = try XCTUnwrap(Library.load(result.meeting.id))
        XCTAssertEqual(saved.status, .pending)
        XCTAssertEqual(saved.bookmarks?.map(\.ms), [250])
        XCTAssertEqual(WavWriter.duration(of: saved.micURL), 1, accuracy: 0.01)
        XCTAssertEqual(Library.loadAll().filter { $0.id == m.id }.count, 1)
    }

    func testARecordingWhoseNameArrivedMeanwhileTakesTheNextOne() throws {
        let staged = try StagingFolder.create(app: label("Taken"))
        try wav(seconds: 1, at: staged.folder.appendingPathComponent("mic.wav"))
        // The same name synced in from another device while this one recorded.
        let other = Paths.meetingsDir.appendingPathComponent(staged.meeting.id, isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("theirs".utf8).write(to: other.appendingPathComponent("notes.md"))

        var m = staged.meeting
        m.status = .pending
        let result = StagingFolder.publish(m)
        XCTAssertTrue(result.moved)
        XCTAssertEqual(result.meeting.id, "\(m.id) 2")
        XCTAssertEqual(Library.load(result.meeting.id)?.status, .pending)
        XCTAssertGreaterThan(Paths.fileSize(result.meeting.micURL), 44)
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("notes.md"), encoding: .utf8), "theirs")
    }

    // MARK: Recovering staging

    func testAnImportCutOffMidDecodeIsClearedNotRecovered() throws {
        let m = try Meeting.newImport(app: label("Import"), at: Date())
        XCTAssertTrue(isStaged(m.id))
        XCTAssertTrue(fm.fileExists(atPath: m.dir.appendingPathComponent(Library.importMarker).path))
        // Half a decode, and no meeting.json yet: exactly what a recording cut short looks like.
        try wav(seconds: 1, at: m.micURL, headerBytes: 0)

        Library.recoverStaged()
        XCTAssertFalse(isStaged(m.id))
        XCTAssertNil(Library.load(m.id), "no truncated duplicate of what will be imported again")
        XCTAssertFalse(fm.fileExists(atPath: Paths.meetingsDir.appendingPathComponent(m.id).path))
    }

    func testARecordingCutShortIsStillRecoveredBesideAnUnfinishedImport() throws {
        let cut = try Meeting.newImport(app: label("Half"), at: Date())
        try wav(seconds: 1, at: cut.micURL, headerBytes: 0)
        let staged = try StagingFolder.create(app: label("Battery"))
        try wav(seconds: 1, at: staged.folder.appendingPathComponent("mic.wav"), headerBytes: 0)

        Library.recoverStaged()
        XCTAssertNil(Library.load(cut.id))
        let recovered = try XCTUnwrap(Library.load(staged.meeting.id), "a recording is never left behind")
        XCTAssertFalse(isStaged(staged.meeting.id))
        XCTAssertEqual(recovered.status, .pending)
        XCTAssertEqual(recovered.duration ?? 0, 1, accuracy: 0.01)
    }

    func testAFinishedMeetingLeftInStagingKeepsItsStatus() throws {
        var done = try Meeting.new(app: label("Done"), staged: true)
        try wav(seconds: 1, at: done.micURL)
        done.status = .done
        Library.save(done)
        var failed = try Meeting.new(app: label("Failed"), staged: true)
        try wav(seconds: 1, at: failed.micURL)
        failed.status = .failed
        failed.error = "The engine gave up."
        Library.save(failed)

        Library.recoverStaged()
        XCTAssertEqual(Library.load(done.id)?.status, .done, "never transcribed again")
        XCTAssertNil(Library.load(done.id)?.error)
        XCTAssertEqual(Library.load(failed.id)?.status, .failed)
        XCTAssertEqual(Library.load(failed.id)?.error, "The engine gave up.")
        XCTAssertFalse(isStaged(done.id))
        XCTAssertFalse(isStaged(failed.id))
    }

    func testAFinishedImportCarriesNoMarker() throws {
        let source = try scratch("memo.wav")
        try wav(seconds: 1, at: source)
        let m = try AudioImport.meeting(from: source, named: "\(label("Memo")).m4a", at: Date())
        XCTAssertEqual(m.dir.deletingLastPathComponent().path, Paths.meetingsDir.path)
        XCTAssertFalse(fm.fileExists(atPath: m.dir.appendingPathComponent(Library.importMarker).path))

        Library.recoverStaged()
        XCTAssertEqual(Library.load(m.id)?.status, .pending, "a finished import is left alone")
    }

    // MARK: Folder names

    func testANewFolderSkipsNamesTakenInEitherPlace() throws {
        let name = label("Busy")
        try fm.createDirectory(at: Paths.meetingsDir.appendingPathComponent(name), withIntermediateDirectories: true)
        try fm.createDirectory(at: Device.stagingDir.appendingPathComponent("\(name) 2"), withIntermediateDirectories: true)
        XCTAssertEqual(try Library.makeFolder(named: name, staged: true), "\(name) 3")
        XCTAssertEqual(try Library.makeFolder(named: name, staged: false), "\(name) 4")
        for leftover in ["\(name) 2", "\(name) 3"] {
            try? fm.removeItem(at: Device.stagingDir.appendingPathComponent(leftover))
        }
    }

    func testImportsStartedTogetherNeverShareAFolder() throws {
        let app = label("Together")
        let date = Date(timeIntervalSince1970: 1_800_500_000)
        let made = Made()
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                let m = try Meeting.new(app: app, at: date, staged: true)
                made.add(m.id)
            } catch {
                made.add(nil)
            }
        }
        let ids = made.ids
        XCTAssertEqual(ids.count, 12)
        XCTAssertFalse(ids.contains(nil), "every one got a folder")
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, 12, "and no two the same")
        for case let id? in ids { try? fm.removeItem(at: Device.stagingDir.appendingPathComponent(id)) }
    }

    // MARK: Watch recordings

    func testAWatchRecordingWithAStaleSizeIsImportedWhole() throws {
        let info = WatchRecordingInfo(startedAt: Date(timeIntervalSince1970: 1_800_600_000), duration: 2)
        let received = try scratch("stale.wav")
        // Two seconds of audio under a header last updated after half a second.
        try wav(seconds: 2, at: received, headerBytes: 16_000)
        try WatchImport.keep(received, info: info)

        XCTAssertTrue(WatchImport.importWaiting().contains(info.id))
        let m = try XCTUnwrap(Library.loadAll().first { $0.app == WatchImport.app && $0.startedAt == info.startedAt })
        XCTAssertEqual(m.duration ?? 0, 2, accuracy: 0.05, "not the half second the header said")
        XCTAssertEqual(WavWriter.duration(of: m.micURL), 2, accuracy: 0.05)
    }

    func testAWavWithTagsAfterItsAudioIsLeftAlone() throws {
        let url = try scratch("tagged.wav")
        let samples = 16_000 * 2
        var file = WavWriter.header(dataBytes: UInt32(samples))
        file.append(Data((0..<samples).map { UInt8(($0 * 3) & 0xFF) }))
        file.append(Data("LIST".utf8))
        file.append(le(4))
        file.append(Data("INFO".utf8))
        file.replaceSubrange(4..<8, with: le(UInt32(file.count - 8)))
        try file.write(to: url)

        XCTAssertFalse(WatchImport.repairSizes(url), "its sizes are right")
        XCTAssertEqual(try Data(contentsOf: url), file)
    }

    func testTheWatchCanAskTheIPhoneToResume() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: WatchCommand.resume.message, format: .binary, options: 0)
        let back = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(WatchCommand(message: back), .resume)
        XCTAssertEqual(WatchCommand.resume.rawValue, "resume", "what an iPhone of the same version expects")
        XCTAssertTrue(WatchCommand.allCases.contains(.resume))
    }
}

/// Folder ids made on several threads at once.
private final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [String?] = []

    func add(_ id: String?) {
        lock.lock()
        made.append(id)
        lock.unlock()
    }

    var ids: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return made
    }
}
