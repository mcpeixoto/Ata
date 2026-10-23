@testable import Ata
import XCTest

/// What lets two devices share one meetings folder: who made a meeting, who
/// is transcribing it, recordings kept out of the folder until they are whole,
/// and the moments marked while recording.
final class SyncGroundworkTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    private let me = DeviceRef(id: "this-mac", name: "Mac")
    private let phone = DeviceRef(id: "the-phone", name: "iPhone")

    private func meeting(_ status: Meeting.Status, origin: DeviceRef? = nil, claim: Claim? = nil) -> Meeting {
        var m = Meeting(id: "m-\(UUID().uuidString)", startedAt: Date(), endedAt: nil, duration: nil,
                        app: nil, status: status, error: nil)
        m.origin = origin
        m.claim = claim
        return m
    }

    private func wav(seconds: Double, at url: URL, headerBytes: UInt32? = nil) throws {
        let samples = Int(seconds * WavWriter.sampleRate)
        var data = WavWriter.header(dataBytes: headerBytes ?? UInt32(samples * 2))
        data.append(Data((0..<samples * 2).map { UInt8(($0 * 7) & 0xFF) }))
        try data.write(to: url)
    }

    private func isInMeetingsFolder(_ m: Meeting) -> Bool {
        m.dir.deletingLastPathComponent().path == Paths.meetingsDir.path
    }

    private func isStaged(_ m: Meeting) -> Bool {
        m.dir.deletingLastPathComponent().path == Device.stagingDir.path
    }

    // MARK: meeting.json

    func testAMeetingSavedBefore26StillLoads() throws {
        let id = "2026-01-05 10.00.00 Zoom \(UUID().uuidString.prefix(6))"
        let dir = Paths.meetingsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        {"app":"Zoom","duration":600,"endedAt":"2026-01-05T10:10:00Z","id":"\(id)",
         "startedAt":"2026-01-05T10:00:00Z","status":"done","transcriptions":[]}
        """.write(to: dir.appendingPathComponent("meeting.json"), atomically: true, encoding: .utf8)

        let m = try XCTUnwrap(Library.load(id))
        XCTAssertEqual(m.status, .done)
        XCTAssertNil(m.origin)
        XCTAssertNil(m.claim)
        XCTAssertNil(m.bookmarks)
        XCTAssertTrue(m.isMine, "a meeting from before devices were recorded is this Mac's")
        XCTAssertTrue(Library.loadAll().contains { $0.id == id })
    }

    func testBookmarksClaimAndOriginAreSavedAndReadBack() throws {
        var m = try Meeting.new(app: "Marks \(UUID().uuidString.prefix(6))")
        XCTAssertEqual(m.origin, Device.current, "new meetings say which device made them")
        m.status = .transcribing
        m.bookmarks = [Bookmark(ms: 12_345, note: "the budget"), Bookmark(ms: 60_000)]
        m.claim = Claim(device: phone, at: Date(timeIntervalSince1970: 1_800_000_000))
        Library.save(m)

        let loaded = try XCTUnwrap(Library.load(m.id))
        XCTAssertEqual(loaded.bookmarks, m.bookmarks)
        XCTAssertEqual(loaded.claim, m.claim)
        XCTAssertEqual(loaded.origin, m.origin)
    }

    func testThisDevicesIDStaysTheSame() {
        XCTAssertFalse(Device.current.id.isEmpty)
        XCTAssertEqual(Device.current.id, Device.current.id)
        XCTAssertEqual(UserDefaults.standard.string(forKey: Device.idKey), Device.current.id)
        XCTAssertEqual(Device.stagingDir.deletingLastPathComponent().path, Paths.supportDir.path)
    }

    // MARK: Whose meeting, who transcribes

    func testOnlyTheDeviceThatMadeAMeetingOwnsIt() {
        XCTAssertTrue(meeting(.done).belongs(to: me), "no origin: made here before 2.6")
        XCTAssertTrue(meeting(.done, origin: me).belongs(to: me))
        XCTAssertFalse(meeting(.done, origin: phone).belongs(to: me))
    }

    func testTwoDevicesNeverBothTranscribeAMeeting() {
        let now = Date()
        XCTAssertTrue(meeting(.pending).canClaim(now: now, by: me), "nobody has it")
        XCTAssertTrue(meeting(.pending, claim: Claim(device: me, at: now)).canClaim(now: now, by: me), "mine already")

        let fresh = Claim(device: phone, at: now.addingTimeInterval(-10 * 60))
        XCTAssertFalse(meeting(.pending, claim: fresh).canClaim(now: now, by: me))
        XCTAssertFalse(meeting(.transcribing, claim: fresh).canClaim(now: now, by: me))
        XCTAssertFalse(meeting(.transcribing, claim: fresh).awaitsTranscript(now: now, by: me))

        // Half an hour without the other device renewing it: it went away mid-job.
        let stale = Claim(device: phone, at: now.addingTimeInterval(-31 * 60))
        XCTAssertTrue(meeting(.pending, claim: stale).canClaim(now: now, by: me))
        XCTAssertTrue(meeting(.transcribing, claim: stale).awaitsTranscript(now: now, by: me))
        XCTAssertFalse(meeting(.done, claim: stale).canClaim(now: now, by: me), "finished, nothing to take over")
        XCTAssertFalse(meeting(.done, claim: stale).awaitsTranscript(now: now, by: me))

        XCTAssertTrue(meeting(.pending, origin: phone).awaitsTranscript(now: now, by: me),
                      "another device's queued meeting can be transcribed here")
        XCTAssertFalse(meeting(.transcribing, claim: Claim(device: me, at: now)).awaitsTranscript(now: now, by: me),
                       "this device's own run isn't started twice")
        XCTAssertFalse(meeting(.recording).awaitsTranscript(now: now, by: me))
    }

    func testAnotherDevicesLiveRecordingIsNeverRequeued() throws {
        var theirs = try Meeting.new(app: "Phone \(UUID().uuidString.prefix(6))")
        theirs.origin = phone
        try wav(seconds: 1, at: theirs.micURL, headerBytes: 0)
        XCTAssertNil(theirs.recovered(by: me), "it may be recording right now")
        XCTAssertEqual(Paths.fileSize(theirs.micURL), 44 + 32_000, "and its files are not touched")

        var mine = try Meeting.new(app: "Mac \(UUID().uuidString.prefix(6))")
        mine.origin = me
        try wav(seconds: 1, at: mine.micURL, headerBytes: 0)
        let recovered = try XCTUnwrap(mine.recovered(by: me))
        XCTAssertEqual(recovered.status, .pending)
        XCTAssertEqual(recovered.duration ?? 0, 1, accuracy: 0.01)

        let theirsRunning = meeting(.transcribing, origin: phone, claim: Claim(device: phone, at: Date()))
        XCTAssertNil(theirsRunning.recovered(by: me), "the other device may still be transcribing it")
        let mineRunning = meeting(.transcribing, origin: phone, claim: Claim(device: me, at: Date()))
        let requeued = try XCTUnwrap(mineRunning.recovered(by: me), "this device's own run was cut short")
        XCTAssertEqual(requeued.status, .pending)
        XCTAssertEqual(requeued.claim?.device, me, "still this device's to finish")
        XCTAssertEqual(meeting(.transcribing).recovered(by: me)?.status, .pending, "from before 2.6")
    }

    // MARK: Staging

    func testARecordingIsWrittenInStagingAndMovedWhole() throws {
        var m = try Meeting.new(app: "Staged \(UUID().uuidString.prefix(6))", staged: true)
        XCTAssertTrue(isStaged(m))
        try wav(seconds: 2, at: m.micURL)
        try wav(seconds: 2, at: m.systemURL)
        let mic = try Data(contentsOf: m.micURL)
        Library.save(m)
        XCTAssertTrue(Library.loadAll().contains { $0.id == m.id }, "the recording in progress is listed")

        m.status = .pending
        Library.save(m)
        let moved = Library.publish(m)
        XCTAssertEqual(moved.id, m.id)
        XCTAssertTrue(isInMeetingsFolder(moved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Device.stagingDir.appendingPathComponent(m.id).path))
        XCTAssertEqual(try Data(contentsOf: moved.micURL), mic, "nothing lost on the way")
        XCTAssertEqual(Paths.fileSize(moved.systemURL), Int64(44 + 64_000))
        XCTAssertEqual(Library.load(moved.id)?.status, .pending)
        XCTAssertEqual(Library.loadAll().filter { $0.id == m.id }.count, 1)
    }

    func testAFailedMoveLeavesTheRecordingWhereItWas() throws {
        let source = FilesTests.root.appendingPathComponent("move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try wav(seconds: 1, at: source.appendingPathComponent("mic.wav"))
        let original = try Data(contentsOf: source.appendingPathComponent("mic.wav"))

        // A file where the folder should be: nothing can be moved into it.
        let blocked = FilesTests.root.appendingPathComponent("blocked-\(UUID().uuidString)")
        try Data("not a folder".utf8).write(to: blocked)
        XCTAssertThrowsError(try Library.moveFolder(source, into: blocked))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("mic.wav")), original)
    }

    func testAMeetingLeftInStagingIsListedAndMovedOnTheNextLaunch() throws {
        var m = try Meeting.new(app: "Left \(UUID().uuidString.prefix(6))", staged: true)
        try wav(seconds: 1, at: m.micURL)
        m.status = .pending  // stopped, but the move failed
        Library.save(m)
        let listed = try XCTUnwrap(Library.loadAll().first { $0.id == m.id })
        XCTAssertTrue(isStaged(listed), "still listed, and transcribed from where it is")

        Library.recoverStaged()
        let moved = try XCTUnwrap(Library.load(m.id))
        XCTAssertTrue(isInMeetingsFolder(moved))
        XCTAssertEqual(moved.status, .pending)
        XCTAssertGreaterThan(Paths.fileSize(moved.micURL), 44)
    }

    func testARecordingCutShortInStagingIsRepairedAndMoved() throws {
        var m = try Meeting.new(app: "Crash \(UUID().uuidString.prefix(6))", staged: true)
        m.bookmarks = [Bookmark(ms: 500)]
        Library.save(m)
        try wav(seconds: 1, at: m.micURL, headerBytes: 0)  // the header never got its final size

        Library.recoverStaged()
        let recovered = try XCTUnwrap(Library.load(m.id))
        XCTAssertTrue(isInMeetingsFolder(recovered))
        XCTAssertEqual(recovered.status, .pending)
        XCTAssertEqual(recovered.duration ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(WavWriter.duration(of: recovered.micURL), 1, accuracy: 0.01)
        XCTAssertEqual(recovered.bookmarks?.map(\.ms), [500])
    }

    func testAStagedFolderWithoutMeetingJSONIsStillRecovered() throws {
        let id = "2026-10-23 09.00.00 Lost \(UUID().uuidString.prefix(6))"
        let dir = Device.stagingDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try wav(seconds: 1, at: dir.appendingPathComponent("mic.wav"), headerBytes: 0)

        Library.recoverStaged()
        let m = try XCTUnwrap(Library.load(id), "the audio is never left behind")
        XCTAssertTrue(isInMeetingsFolder(m))
        XCTAssertEqual(m.status, .pending)
    }

    func testAMoveThatCopiedEverythingFinishesWithoutDuplicating() throws {
        let parent = FilesTests.root.appendingPathComponent("into-\(UUID().uuidString)", isDirectory: true)
        let source = FilesTests.root.appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try wav(seconds: 1, at: source.appendingPathComponent("mic.wav"))
        let copy = parent.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)

        XCTAssertEqual(try Library.moveFolder(source, into: parent).path, copy.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 1)
    }

    func testAMoveNeverOverwritesAnotherFolder() throws {
        let parent = FilesTests.root.appendingPathComponent("into-\(UUID().uuidString)", isDirectory: true)
        let source = FilesTests.root.appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try wav(seconds: 1, at: source.appendingPathComponent("mic.wav"))
        let other = parent.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try wav(seconds: 3, at: other.appendingPathComponent("mic.wav"))

        let moved = try Library.moveFolder(source, into: parent)
        XCTAssertEqual(moved.lastPathComponent, source.lastPathComponent + " 2")
        XCTAssertEqual(WavWriter.duration(of: other.appendingPathComponent("mic.wav")), 3, accuracy: 0.01)
        XCTAssertEqual(WavWriter.duration(of: moved.appendingPathComponent("mic.wav")), 1, accuracy: 0.01)
    }

    // MARK: Import

    func testAnImportedFileBecomesAPendingMeetingAndIsLeftAlone() throws {
        let folder = FilesTests.root.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("Voice memo.wav")
        try wav(seconds: 2, at: source)
        let before = try Data(contentsOf: source)
        let created = try XCTUnwrap(source.resourceValues(forKeys: [.creationDateKey]).creationDate)

        let m = try AudioImport.meeting(from: source)
        XCTAssertEqual(m.status, .pending)
        XCTAssertEqual(m.app, "Voice memo")
        XCTAssertTrue(m.isMine)
        XCTAssertTrue(isInMeetingsFolder(m))
        XCTAssertEqual(m.duration ?? 0, 2, accuracy: 0.05)
        XCTAssertEqual(WavWriter.duration(of: m.micURL), 2, accuracy: 0.05)
        XCTAssertNil(m.systemAudioURL)
        XCTAssertEqual(m.startedAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(Library.load(m.id)?.status, .pending)

        XCTAssertEqual(try Data(contentsOf: source), before, "the source file is only read")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Voice memo.wav"])

        let again = try AudioImport.meeting(from: source)
        XCTAssertNotEqual(again.id, m.id, "a second import never writes into the first one's folder")
        XCTAssertNotNil(Library.load(m.id))
    }

    func testAFileThatIsNotAudioIsNotImported() throws {
        XCTAssertTrue(AudioImport.accepts(URL(fileURLWithPath: "/tmp/a.m4a")))
        XCTAssertTrue(AudioImport.accepts(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertTrue(AudioImport.accepts(URL(fileURLWithPath: "/tmp/a.wav")))
        XCTAssertFalse(AudioImport.accepts(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(AudioImport.accepts(URL(string: "https://example.com/a.mp3")!))
        XCTAssertEqual(AudioImport.label(for: URL(fileURLWithPath: "/tmp/Call: Ana.m4a")), "Call- Ana")

        let folder = FilesTests.root.appendingPathComponent("broken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let broken = folder.appendingPathComponent("Broken \(UUID().uuidString.prefix(6)).wav")
        try Data("this is not audio".utf8).write(to: broken)
        let staged = Library.stagedIDs()
        XCTAssertThrowsError(try AudioImport.meeting(from: broken))
        XCTAssertEqual(Library.stagedIDs(), staged, "the half-written copy is removed")
        XCTAssertFalse(Library.loadAll().contains { $0.app == broken.deletingPathExtension().lastPathComponent })
        XCTAssertEqual(try String(contentsOf: broken, encoding: .utf8), "this is not audio")
    }

    // MARK: Bookmarks

    func testAMarkPointsAtTheLineBeingSaidOrTheClosestOne() {
        let starts = [0, 5_000, 20_000], ends = [2_000, 8_000, 25_000]
        XCTAssertEqual(Bookmark.nearest(to: 6_000, starts: starts, ends: ends), 1, "during")
        XCTAssertEqual(Bookmark.nearest(to: 9_000, starts: starts, ends: ends), 1, "just after")
        XCTAssertEqual(Bookmark.nearest(to: 15_000, starts: starts, ends: ends), 1, "near tie: the line before")
        XCTAssertEqual(Bookmark.nearest(to: 18_000, starts: starts, ends: ends), 2, "just before the next")
        XCTAssertEqual(Bookmark.nearest(to: 60_000, starts: starts, ends: ends), 2)
        XCTAssertNil(Bookmark.nearest(to: 1_000, starts: [], ends: []))
    }

    func testTheMeetingWindowListsMarksInOrderAndPlaysFromTheirLine() {
        let lines = [
            MeetingModel.Line(id: 0, start: 0, end: 4_000, speaker: Speakers.me, name: "Ana", text: "Hello", words: []),
            MeetingModel.Line(id: 1, start: 5_000, end: 9_000, speaker: "S1", name: "Rui", text: "The budget", words: []),
        ]
        let moments = MeetingModel.moments([Bookmark(ms: 8_000, note: "budget"), Bookmark(ms: 1_000)], in: lines)
        XCTAssertEqual(moments.map(\.bookmark.ms), [1_000, 8_000])
        XCTAssertEqual(moments.map { $0.line?.id }, [0, 1])
        XCTAssertEqual(moments[1].playFromMs, 5_000, "from the start of the line it points at")
        XCTAssertEqual(MeetingModel.moments([Bookmark(ms: 3_000)], in: []).first?.playFromMs, 3_000)
    }

    func testMarkedMomentsAreWrittenIntoTheTranscript() throws {
        let blocks: [StoredTranscript.Line] = [
            .init(start: 0, end: 2_000, text: "Morning everyone", speaker: Speakers.me),
            .init(start: 2_500, end: 5_000, text: "The budget is approved", speaker: "S1"),
        ]
        let names: (String) -> String = { $0 == Speakers.me ? "Ana" : "Rui" }
        let marks = [Bookmark(ms: 61_000), Bookmark(ms: 4_000, note: "budget ")]
        XCTAssertEqual(Transcriber.moments(marks, in: blocks, coarse: false, names: names), """
        ## Moments you marked

        - **[00:04] Rui:** The budget is approved — _budget_
        - **[01:01] Rui:** The budget is approved


        """)
        XCTAssertEqual(Transcriber.moments(marks, in: blocks, coarse: true, names: names), """
        ## Moments you marked

        - **[00:04]** — _budget_
        - **[01:01]**


        """, "without line times, only the times")
        XCTAssertEqual(Transcriber.moments([], in: blocks, coarse: false, names: names), "")

        var m = try Meeting.new(app: "Moments \(UUID().uuidString.prefix(6))")
        let stored = StoredTranscript(segments: blocks, coarse: false, summary: nil, engine: "local", model: "large-v3")
        XCTAssertFalse(Transcriber.render(stored, meeting: m, names: names).contains("Moments you marked"))
        m.bookmarks = marks
        let md = Transcriber.render(stored, meeting: m, names: names)
        let section = try XCTUnwrap(md.range(of: "## Moments you marked"))
        let transcript = try XCTUnwrap(md.range(of: "**[00:00] Ana:** Morning everyone"))
        XCTAssertLessThan(section.lowerBound, transcript.lowerBound, "above the transcript, with the summary")
    }

    func testALongLineIsCutToTheWordsAroundTheMark() {
        let words = (0..<100).map { StoredTranscript.Word(start: $0 * 1_000, end: $0 * 1_000 + 800, text: "w\($0)") }
        let line = StoredTranscript.Line(start: 0, end: 100_000, text: words.map(\.text).joined(separator: " "),
                                         speaker: "S1", words: words)
        XCTAssertEqual(Transcriber.excerpt(of: line, around: 50_000),
                       "…" + (40...54).map { "w\($0)" }.joined(separator: " ") + "…")
        let short = StoredTranscript.Line(start: 0, end: 1_000, text: "Short", speaker: "S1")
        XCTAssertEqual(Transcriber.excerpt(of: short, around: 500), "Short")
    }
}
