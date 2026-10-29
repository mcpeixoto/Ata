@testable import Ata
import XCTest

/// iCloud sync where it can go wrong: the container going away, turning sync off,
/// a run that ends while meeting.json is still in iCloud or was edited on the other
/// device, audio that never arrives, and conflicts settled twice. Everything happens
/// in temporary folders; nothing here talks to iCloud.
final class SyncHardeningTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    private let fm = FileManager.default
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FilesTests.root.appendingPathComponent("sync-hardening-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CloudLibrary.use(.local)
        try? fm.removeItem(at: scratch)
    }

    private let mac = DeviceRef(id: "mac-under-test", name: "Mac")
    private let phone = DeviceRef(id: "phone-under-test", name: "iPhone")

    private func meeting(_ id: String, status: Meeting.Status = .transcribing, claim: DeviceRef? = nil) -> Meeting {
        var m = Meeting(id: id, startedAt: Date(timeIntervalSince1970: 1_767_600_000), endedAt: nil, duration: 60,
                        app: "Zoom", status: status, error: nil)
        m.origin = phone
        m.claim = claim.map { Claim(device: $0, at: Date()) }
        return m
    }

    private func record() -> TranscriptionRecord {
        TranscriptionRecord(engine: "local", model: "large-v3-turbo", finishedAt: Date(), audioSeconds: 60,
                            processingSeconds: 5, costUSD: 0, words: 100, mySpeechSeconds: 30,
                            othersSpeechSeconds: 30, archivedAs: nil)
    }

    // MARK: 1. The container going away

    func testNeverMakesTheContainerAgainOnceItIsGone() throws {
        let documents = scratch.appendingPathComponent("Mobile Documents/iCloud~ai~interactive~ata/Documents",
                                                       isDirectory: true)
        let cloud = LibraryLocation.cloud(documents)

        // Signed out: the container is gone, and must stay gone.
        XCTAssertThrowsError(try CloudLibrary.createFolder(cloud.meetings, location: cloud))
        XCTAssertThrowsError(try CloudLibrary.createFolder(cloud.voices, location: cloud))
        XCTAssertFalse(fm.fileExists(atPath: documents.path), "no plain folder where iCloud was")
        XCTAssertFalse(fm.fileExists(atPath: documents.deletingLastPathComponent().path))

        // Container there: Meetings and a meeting folder below it are made as before.
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try CloudLibrary.createFolder(cloud.meetings.appendingPathComponent("2026-10-29 10.00.00 Zoom"), location: cloud)
        XCTAssertTrue(CloudLibrary.isDirectory(cloud.meetings.appendingPathComponent("2026-10-29 10.00.00 Zoom")))

        // This device's own folders, and anything outside the container, are made whole.
        let local = scratch.appendingPathComponent("a/b/Meetings", isDirectory: true)
        try CloudLibrary.createFolder(local, location: cloud)
        XCTAssertTrue(CloudLibrary.isDirectory(local))
        let elsewhere = scratch.appendingPathComponent("c/d", isDirectory: true)
        try CloudLibrary.createFolder(elsewhere, location: .local)
        XCTAssertTrue(CloudLibrary.isDirectory(elsewhere))
    }

    func testAPlainFolderWhereTheContainerWasIsNotICloud() throws {
        let plain = scratch.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertFalse(CloudLibrary.isReal(plain))

        let saved = UserDefaults.standard.object(forKey: Pref.iCloudDocuments)
        defer { UserDefaults.standard.set(saved, forKey: Pref.iCloudDocuments) }
        UserDefaults.standard.set(plain.path, forKey: Pref.iCloudDocuments)
        XCTAssertNotEqual(CloudLibrary.knownDocuments()?.standardizedFileURL, plain.standardizedFileURL,
                          "a launch never picks a leftover local folder as the library in iCloud")
    }

    // MARK: 3. A run ending while meeting.json is still in iCloud

    func testARunWaitsForMeetingJSONAndLetsATakeoverWin() async {
        let id = "2026-10-29 11.00.00 Zoom"
        let placeholder = Library.placeholder(id: id, in: scratch)
        // The Mac took it over while this iPhone was away; the file arrives once asked for.
        var onDisk: Meeting? = placeholder
        var asked: [URL] = []
        let fresh = await RunEnd.fresh(id, timeout: 1, load: { _ in onDisk }) { urls, _ in
            asked = urls
            onDisk = self.meeting(id, claim: self.mac)
            return true
        }
        XCTAssertEqual(asked.map(\.lastPathComponent), ["meeting.json"], "meeting.json is asked for")
        XCTAssertNil(RunEnd.outcome(.done, over: fresh, by: phone, apply: RunEnd.done(.init(record: record(), archivedPrevious: nil))),
                     "the stale device saves nothing over the device that took over")
        XCTAssertNil(RunEnd.outcome(.failed, over: fresh, by: phone))
        XCTAssertNil(RunEnd.outcome(.pending, over: fresh, by: phone))
    }

    func testARunSavesNothingWhileMeetingJSONNeverArrives() async {
        let id = "2026-10-29 11.30.00 Zoom"
        let placeholder = Library.placeholder(id: id, in: scratch)
        let fresh = await RunEnd.fresh(id, timeout: 1, load: { _ in placeholder }) { _, _ in false }
        XCTAssertEqual(fresh, .unknown)
        XCTAssertNil(RunEnd.outcome(.done, over: fresh, by: phone), "unknown is not 'mine'")
        XCTAssertNil(RunEnd.outcome(.failed, over: fresh, by: phone))

        // Deleted meanwhile: never brought back.
        let gone = await RunEnd.fresh(id, timeout: 1, load: { _ in nil }) { _, _ in true }
        XCTAssertEqual(gone, .gone)
        XCTAssertNil(RunEnd.outcome(.done, over: gone, by: phone))
    }

    func testARunThatEndedUnknownIsPickedUpAgainOnceMeetingJSONArrives() {
        let id = "orphan-\(UUID().uuidString)"
        let mine = meeting(id, claim: Device.current)
        XCTAssertFalse(RunEnd.awaits(mine), "an own run in progress is not queued twice")
        RunEnd.markOrphan(id)
        XCTAssertTrue(RunEnd.awaits(mine), "an own run that ended without saving is done again")
        var theirs = mine
        theirs.claim = Claim(device: mac, at: Date())
        XCTAssertFalse(RunEnd.awaits(theirs), "unless another device has it now")
        XCTAssertFalse(RunEnd.awaits(Library.placeholder(id: id, in: scratch)))
    }

    // MARK: 4. Edits made on the other device during the run

    func testARunKeepsWhatTheOtherDeviceChangedMeanwhile() async {
        let id = "2026-10-29 12.00.00 Zoom"
        var edited = meeting(id, claim: phone)
        edited.event = MeetingEvent(title: "Board review", startsAt: Date(timeIntervalSince1970: 1_767_600_000))
        edited.bookmarks = [Bookmark(ms: 1_000, note: "added on the Mac")]
        let fresh = await RunEnd.fresh(id, timeout: 1, load: { _ in edited }) { _, _ in
            XCTFail("a meeting.json on this device is not downloaded")
            return true
        }
        let saved = RunEnd.outcome(.done, over: fresh, by: phone,
                                   apply: RunEnd.done(.init(record: record(), archivedPrevious: nil)))
        XCTAssertEqual(saved?.status, .done)
        XCTAssertNil(saved?.claim)
        XCTAssertEqual(saved?.transcriptions?.count, 1)
        XCTAssertEqual(saved?.event?.title, "Board review", "the title set on the other device survives")
        XCTAssertEqual(saved?.bookmarks?.first?.note, "added on the Mac")
        XCTAssertEqual(saved?.title, "Board review")
    }

    @MainActor
    func testSavingARunReadsMeetingJSONFromDisk() async throws {
        let id = "2026-10-29 12.30.00 Zoom \(UUID().uuidString.prefix(6))"
        var m = meeting(id, claim: Device.current)
        m.transcriptions = [record()]
        try fm.createDirectory(at: m.dir, withIntermediateDirectories: true)
        Library.save(m)
        // Renamed on the other device after this one claimed it.
        var renamed = m
        renamed.event = MeetingEvent(title: "Renamed", startsAt: m.startedAt)
        Library.save(renamed)

        let saved = await RunEnd.save(id, as: .done,
                                      apply: RunEnd.done(.init(record: record(), archivedPrevious: "transcript-1.md")))
        let read = try XCTUnwrap(Library.load(id))
        XCTAssertEqual(saved?.status, .done)
        XCTAssertEqual(read.event?.title, "Renamed")
        XCTAssertEqual(read.status, .done)
        XCTAssertEqual(read.transcriptions?.count, 2)
        XCTAssertEqual(read.transcriptions?.first?.archivedAs, "transcript-1.md")

        // Taken over by another device: nothing saved at all.
        var taken = read
        taken.status = .transcribing
        taken.claim = Claim(device: mac, at: Date())
        Library.save(taken)
        let refused = await RunEnd.save(id, as: .failed) { $0.error = "boom" }
        XCTAssertNil(refused)
        let after = try XCTUnwrap(Library.load(id))
        XCTAssertEqual(after.status, .transcribing)
        XCTAssertEqual(after.claim?.device, mac)
        XCTAssertNil(after.error)
        try? fm.removeItem(at: m.dir)
    }

    // MARK: 5. Audio that never arrives

    func testAudioStillInICloudReleasesTheClaimInsteadOfFailing() {
        XCTAssertTrue(RunEnd.releasesClaim(CloudFiles.Failure.notDownloaded))
        XCTAssertTrue(RunEnd.releasesClaim(CloudFiles.Failure.transcriptNotDownloaded))
        XCTAssertFalse(RunEnd.releasesClaim(TranscriberError.cancelled))
        XCTAssertFalse(RunEnd.releasesClaim(TranscriberError.noAudio))
        XCTAssertFalse(RunEnd.releasesClaim(CocoaError(.fileReadCorruptFile)))
    }

    func testAMeetingWhoseAudioDidNotArriveWaitsBeforeTheNextTry() {
        let id = "late-audio-\(UUID().uuidString)"
        let now = Date()
        let pending = meeting(id, status: .pending)
        XCTAssertTrue(RunEnd.awaits(pending, now: now))
        RunEnd.retryLater(id, now: now)
        XCTAssertFalse(RunEnd.awaits(pending, now: now.addingTimeInterval(60)), "not straight back into the queue")
        XCTAssertTrue(RunEnd.awaits(pending, now: now.addingTimeInterval(RunEnd.retryAfter + 1)))
    }

    // MARK: 6. Conflicts settled once

    func testAConflictIsNotSettledTwiceAtOnce() {
        let url = scratch.appendingPathComponent("notes.md")
        XCTAssertTrue(Conflicts.begin(url))
        XCTAssertFalse(Conflicts.begin(url), "a second pass waits for the first")
        Conflicts.end(url)
        XCTAssertTrue(Conflicts.begin(url))
        Conflicts.end(url)
    }

    // MARK: 2. Turning iCloud off

    private struct Libraries {
        let local: URL
        let cloud: URL
        let ledger: URL
        var into: CloudMigration { CloudMigration(source: local, destination: cloud, ledgerURL: ledger, device: DeviceRef(id: "phone-under-test", name: "iPhone")) }
        var out: CloudCopyOut { CloudCopyOut(cloud: cloud, local: local, ledgerURL: ledger, timeout: 1) { _, _ in true } }
    }

    private func libraries() -> Libraries {
        Libraries(local: scratch.appendingPathComponent("Local", isDirectory: true),
                  cloud: scratch.appendingPathComponent("Documents/Meetings", isDirectory: true),
                  ledger: scratch.appendingPathComponent("support/icloud-copy.json"))
    }

    private func makeFolder(_ name: String, in parent: URL, notes: String) throws {
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        var m = meeting(name, status: .done)
        m.claim = nil
        try e.encode(m).write(to: folder.appendingPathComponent("meeting.json"))
        try Data((0..<150_000).map { UInt8(($0 * 3 + name.count) & 0xFF) }).write(to: folder.appendingPathComponent("mic.wav"))
        try Data(notes.utf8).write(to: folder.appendingPathComponent("notes.md"))
    }

    private func setModified(_ url: URL, _ seconds: Double) throws {
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testTurningOffBringsEveryMeetingBackFromICloudAndLeavesICloudAlone() async throws {
        let lib = libraries()
        let mine = "2026-10-01 09.00.00 Voice Memo"
        try makeFolder(mine, in: lib.local, notes: "mine")
        XCTAssertEqual(lib.into.run().copied, [mine])
        // The iPhone removed its original once the copy was uploaded…
        try fm.removeItem(at: lib.local.appendingPathComponent(mine))
        // …and the Mac recorded another one straight into iCloud.
        let theirs = "2026-10-02 10.00.00 Zoom"
        try makeFolder(theirs, in: lib.cloud, notes: "theirs")
        let before = [mine, theirs].map { CloudMigration.stamps(of: lib.cloud.appendingPathComponent($0)) }

        XCTAssertEqual(Set(lib.out.pending()), [mine, theirs])
        let outcome = await lib.out.run()
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(Set(outcome.copied), [mine, theirs])

        for name in [mine, theirs] {
            XCTAssertTrue(CloudMigration.verified(lib.local.appendingPathComponent(name),
                                                  against: lib.cloud.appendingPathComponent(name)), name)
        }
        XCTAssertEqual([mine, theirs].map { CloudMigration.stamps(of: lib.cloud.appendingPathComponent($0)) }, before,
                       "nothing in iCloud is changed")
        XCTAssertTrue(lib.out.isComplete)
        XCTAssertEqual(lib.into.pending(), [], "turning it on again copies nothing back as a change")
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: lib.local.path).contains { $0.hasSuffix(".partial") })
    }

    func testTurningOffNeverWritesIntoAnotherMeetingByTheSameName() async throws {
        let lib = libraries()
        let name = "2026-10-03 09.00.00 Zoom"
        try makeFolder(name, in: lib.local, notes: "recorded here while iCloud was away")
        try makeFolder(name, in: lib.cloud, notes: "recorded on the other device")
        _ = await lib.out.run()
        XCTAssertEqual(try text(lib.local.appendingPathComponent("\(name)/notes.md")),
                       "recorded here while iCloud was away")
        XCTAssertEqual(try text(lib.local.appendingPathComponent("\(name) 2/notes.md")),
                       "recorded on the other device")
        XCTAssertTrue(lib.out.isComplete)
    }

    func testTurningOffKeepsBothVersionsOfAFileChangedOnBothSides() async throws {
        let lib = libraries()
        let a = "2026-10-04 09.00.00 Zoom"
        let b = "2026-10-05 09.00.00 Zoom"
        try makeFolder(a, in: lib.local, notes: "a")
        try makeFolder(b, in: lib.local, notes: "b")
        XCTAssertEqual(Set(lib.into.run().copied), [a, b])

        // Changed in iCloud only: this device takes iCloud's.
        let cloudA = lib.cloud.appendingPathComponent("\(a)/notes.md")
        try Data("a, edited on the Mac".utf8).write(to: cloudA)
        try setModified(cloudA, 1_800_000_000)
        // Changed on both: this device's stays, iCloud's goes beside it.
        let cloudB = lib.cloud.appendingPathComponent("\(b)/notes.md")
        try Data("b, edited on the Mac".utf8).write(to: cloudB)
        try setModified(cloudB, 1_800_000_000)
        let localB = lib.local.appendingPathComponent("\(b)/notes.md")
        try Data("b, edited here".utf8).write(to: localB)
        try setModified(localB, 1_800_000_100)

        XCTAssertEqual(Set(lib.out.pending()), [a, b])
        let outcome = await lib.out.run()
        XCTAssertEqual(outcome.failed, [])
        XCTAssertEqual(try text(lib.local.appendingPathComponent("\(a)/notes.md")), "a, edited on the Mac")
        XCTAssertEqual(try text(localB), "b, edited here")
        XCTAssertEqual(try text(lib.local.appendingPathComponent("\(b)/notes (other device).md")), "b, edited on the Mac")
        XCTAssertEqual(try text(cloudB), "b, edited on the Mac", "iCloud is untouched")
    }

    func testTurningOffStaysInICloudWhenAMeetingDoesNotDownload() async throws {
        let lib = libraries()
        let name = "2026-10-06 09.00.00 Zoom"
        try makeFolder(name, in: lib.cloud, notes: "only in iCloud")
        let offline = CloudCopyOut(cloud: lib.cloud, local: lib.local, ledgerURL: lib.ledger, timeout: 1) { _, _ in false }
        let outcome = await offline.run()
        XCTAssertEqual(outcome.failed, [name])
        XCTAssertFalse(fm.fileExists(atPath: lib.local.appendingPathComponent(name).path))
        XCTAssertFalse(offline.isComplete, "so the library does not move")
    }

    func testFilesStillInICloudCountUnderTheirRealNames() throws {
        let folder = scratch.appendingPathComponent("m", isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("versions"), withIntermediateDirectories: true)
        for name in ["meeting.json", ".mic.wav.icloud", ".notes.md.partial", ".DS_Store", "versions/transcript-1.md"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        XCTAssertEqual(CloudCopyOut.files(in: folder), ["meeting.json", "mic.wav", "versions/transcript-1.md"])
    }
}
