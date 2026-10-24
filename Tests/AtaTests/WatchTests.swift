@testable import Ata
import XCTest

/// The Apple Watch app's side of things that can be checked without a Watch:
/// what it and the iPhone send each other, the outbox that never lets a
/// recording go before the iPhone has it, and the iPhone's import.
final class WatchTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    /// What WatchConnectivity hands over: Foundation objects, numbers as NSNumber.
    private func roundTrip(_ d: [String: Any]) -> [String: Any] {
        let data = try! PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0)
        return try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    }

    private func wav(seconds: Double, at url: URL) throws {
        let samples = Int(seconds * WavWriter.sampleRate)
        var data = WavWriter.header(dataBytes: UInt32(samples * 2))
        data.append(Data((0..<samples * 2).map { UInt8(($0 * 7) & 0xFF) }))
        try data.write(to: url)
    }

    /// What the inbox holds for one recording.
    private func waiting(_ id: UUID) -> [WatchRecordingInfo] {
        WatchImport.waiting().map { $0.info }.filter { $0.id == id }
    }

    /// One second of 16 kHz audio as a recorder that never finished leaves it:
    /// a filler chunk before the data, and both sizes still at zero. Returns the samples.
    private func cutShortWav(at url: URL) throws -> Data {
        let fmt = WavWriter.header(dataBytes: 0).subdata(in: 12..<36)
        var file = Data("RIFF".utf8)
        file += Data([0, 0, 0, 0])
        file += Data("WAVE".utf8)
        file += fmt
        file += Data("FLLR".utf8)
        file += Data([12, 0, 0, 0])
        file += Data(count: 12)
        file += Data("data".utf8)
        file += Data([0, 0, 0, 0])
        let samples = Data((0..<32_000).map { UInt8(($0 * 7) & 0xFF) })
        file += samples
        try file.write(to: url)
        return samples
    }

    private func inboxFile(_ name: String) -> URL {
        let folder = FilesTests.root.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    // MARK: Messages

    func testCommandsSurviveTheTrip() {
        for command in WatchCommand.allCases {
            XCTAssertEqual(WatchCommand(message: roundTrip(command.message)), command)
        }
        XCTAssertNil(WatchCommand(message: ["kind": "command", "command": "dance"]))
        XCTAssertNil(WatchCommand(message: WatchPhoneState.idle.dictionary), "a state is not a command")
        XCTAssertNil(WatchCommand(message: [:]))
    }

    func testTheIPhonesStateSurvivesTheTrip() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recording = WatchPhoneState(phase: .recording, recorded: 65, at: now, bookmarks: 2)
        let back = try XCTUnwrap(WatchPhoneState(dictionary: roundTrip(recording.dictionary)))
        XCTAssertEqual(back, recording)
        XCTAssertTrue(back.isActive)
        XCTAssertEqual(back.clock.elapsed(at: now.addingTimeInterval(10)), 75, accuracy: 0.001)

        let refused = WatchPhoneState(phase: .idle, recorded: 0, at: now, bookmarks: 0,
                                      problem: .failed, detail: "No active microphone was found.")
        let refusedBack = try XCTUnwrap(WatchPhoneState(dictionary: roundTrip(refused.dictionary)))
        XCTAssertEqual(refusedBack.problem, .failed)
        XCTAssertEqual(refusedBack.detail, "No active microphone was found.")
        XCTAssertFalse(refusedBack.isActive)

        XCTAssertNil(WatchPhoneState(dictionary: WatchCommand.start.message))
        XCTAssertNil(WatchPhoneState(dictionary: ["kind": "state", "phase": "flying", "recorded": 1]))
    }

    func testAnInterruptedRecordingsTimeStandsStill() {
        let now = Date()
        let paused = WatchPhoneState(phase: .interrupted, recorded: 30, at: now, bookmarks: 0)
        XCTAssertTrue(paused.isActive)
        XCTAssertNil(paused.clock.timerStart)
        XCTAssertEqual(paused.clock.elapsed(at: now.addingTimeInterval(600)), 30)
        XCTAssertEqual(WatchPhoneState(dictionary: roundTrip(paused.dictionary))?.clock.since, nil)
    }

    func testTheClockCountsOnlyWhileRunning() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var clock = WatchClock()
        clock.run(at: t0)
        clock.run(at: t0.addingTimeInterval(5))  // already running: no restart
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(10)), 10)
        clock.pause(at: t0.addingTimeInterval(10))
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(100)), 10)
        clock.run(at: t0.addingTimeInterval(100))
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(105)), 15)
        XCTAssertEqual(clock.timerStart, t0.addingTimeInterval(90))
        XCTAssertEqual(clock.elapsed(at: t0), 10, "a clock that is behind never counts backwards")
    }

    func testTheTimeReadsLikeAClock() {
        XCTAssertEqual(WatchFormat.clock(0), "0:00")
        XCTAssertEqual(WatchFormat.clock(5.9), "0:05")
        XCTAssertEqual(WatchFormat.clock(754), "12:34")
        XCTAssertEqual(WatchFormat.clock(3723), "1:02:03")
        XCTAssertEqual(WatchFormat.clock(-3), "0:00")
    }

    func testARecordingsDetailsSurviveTheTrip() throws {
        let info = WatchRecordingInfo(startedAt: Date(timeIntervalSince1970: 1_800_000_123),
                                      duration: 92.5, bookmarks: [1_200, 45_000])
        let back = try XCTUnwrap(WatchRecordingInfo(metadata: roundTrip(info.metadata)))
        XCTAssertEqual(back, info)
        XCTAssertNil(WatchRecordingInfo(metadata: nil))
        XCTAssertNil(WatchRecordingInfo(metadata: ["kind": "recording", "id": "not a uuid", "startedAt": Date()]))
        XCTAssertNil(WatchRecordingInfo(metadata: WatchAck.message(for: info.id)))
    }

    func testTheConfirmationNamesTheRecording() {
        let id = UUID()
        XCTAssertEqual(WatchAck.id(from: roundTrip(WatchAck.message(for: id))), id)
        XCTAssertNil(WatchAck.id(from: WatchCommand.stop.message))
    }

    // MARK: Outbox

    private func info(_ seconds: TimeInterval = 0) -> WatchRecordingInfo {
        WatchRecordingInfo(startedAt: Date(timeIntervalSince1970: 1_000 + seconds), duration: 10)
    }

    func testARecordingLeavesTheOutboxOnlyWhenTheIPhoneConfirmsIt() throws {
        let t0 = Date(timeIntervalSince1970: 10_000)
        var outbox = WatchOutbox()
        let a = info()
        outbox.add(a, file: "a.wav")
        outbox.add(a, file: "a.wav")
        XCTAssertEqual(outbox.items.count, 1, "the same recording is listed once")

        XCTAssertEqual(outbox.due(at: t0, inFlight: []).map(\.id), [a.id])
        XCTAssertEqual(outbox.due(at: t0, inFlight: [a.id]), [], "not sent twice while it is being sent")

        outbox.transferFinished(a.id, failed: false, at: t0)
        XCTAssertEqual(outbox.items.first?.state, .delivered)
        XCTAssertEqual(outbox.items.count, 1, "delivered is not confirmed: the Watch keeps its copy")
        XCTAssertEqual(outbox.due(at: t0.addingTimeInterval(60), inFlight: []), [])

        XCTAssertNil(outbox.confirmed(UUID()), "a confirmation for something else deletes nothing")
        let confirmed = try XCTUnwrap(outbox.confirmed(a.id))
        XCTAssertEqual(confirmed.file, "a.wav")
        XCTAssertTrue(outbox.isEmpty)
        XCTAssertNil(outbox.confirmed(a.id))
    }

    func testAFailedTransferIsSentAgain() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        var outbox = WatchOutbox()
        let a = info()
        outbox.add(a, file: "a.wav")
        _ = outbox.due(at: t0, inFlight: [])
        outbox.transferFinished(a.id, failed: true, at: t0)
        XCTAssertEqual(outbox.items.first?.state, .waiting)
        XCTAssertEqual(outbox.items.count, 1)
        XCTAssertEqual(outbox.due(at: t0, inFlight: []).map(\.id), [a.id])
    }

    func testATransferLostWithTheAppIsSentAgain() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        var outbox = WatchOutbox()
        let a = info(), b = info(1)
        outbox.add(a, file: "a.wav")
        outbox.add(b, file: "b.wav")
        XCTAssertEqual(outbox.due(at: t0, inFlight: []).count, 2)
        // Relaunched: WatchConnectivity still has b, not a.
        XCTAssertEqual(outbox.due(at: t0.addingTimeInterval(5), inFlight: [b.id]).map(\.id), [a.id])
    }

    func testAnUnconfirmedDeliveryIsSentAgainAfterAnHour() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        var outbox = WatchOutbox()
        let a = info()
        outbox.add(a, file: "a.wav")
        _ = outbox.due(at: t0, inFlight: [])
        outbox.transferFinished(a.id, failed: false, at: t0)
        XCTAssertEqual(outbox.due(at: t0.addingTimeInterval(WatchOutbox.confirmationTimeout - 1), inFlight: []), [])
        XCTAssertEqual(outbox.due(at: t0.addingTimeInterval(WatchOutbox.confirmationTimeout + 1), inFlight: []).map(\.id),
                       [a.id])
        XCTAssertEqual(outbox.items.count, 1)
    }

    func testTheOutboxIsKeptAcrossLaunches() throws {
        var outbox = WatchOutbox()
        outbox.add(WatchRecordingInfo(startedAt: Date(timeIntervalSince1970: 5), duration: 3, bookmarks: [100]),
                   file: "a.wav")
        _ = outbox.due(at: Date(timeIntervalSince1970: 10), inFlight: [])
        let data = try JSONEncoder().encode(outbox)
        XCTAssertEqual(try JSONDecoder().decode(WatchOutbox.self, from: data), outbox)
    }

    // MARK: Import on the iPhone

    func testAWatchRecordingBecomesAPendingMeetingWithItsBookmarks() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let info = WatchRecordingInfo(startedAt: started, duration: 2, bookmarks: [1_500, 300])
        let received = inboxFile("received.wav")
        try wav(seconds: 2, at: received)

        try WatchImport.keep(received, info: info)
        XCTAssertFalse(FileManager.default.fileExists(atPath: received.path), "moved out before WatchConnectivity deletes it")
        XCTAssertEqual(waiting(info.id), [info])

        XCTAssertTrue(WatchImport.importWaiting().contains(info.id))
        XCTAssertEqual(waiting(info.id), [], "the inbox copy goes once it is a meeting")

        let m = try XCTUnwrap(Library.loadAll().first { $0.app == WatchImport.app && $0.startedAt == started })
        XCTAssertEqual(m.status, .pending)
        XCTAssertTrue(m.isMine, "made by this device")
        XCTAssertEqual(m.origin, Device.current)
        XCTAssertEqual(m.duration ?? 0, 2, accuracy: 0.05)
        XCTAssertEqual(m.bookmarks?.map(\.ms), [300, 1_500])
        XCTAssertEqual(WavWriter.duration(of: m.micURL), 2, accuracy: 0.05)
        XCTAssertEqual(m.dir.deletingLastPathComponent().path, Paths.meetingsDir.path)
    }

    func testARecordingSentTwiceIsImportedOnceAndConfirmedAgain() throws {
        let info = WatchRecordingInfo(startedAt: Date(timeIntervalSince1970: 1_800_100_000), duration: 1)
        let first = inboxFile("first.wav")
        try wav(seconds: 1, at: first)
        try WatchImport.keep(first, info: info)
        XCTAssertTrue(WatchImport.importWaiting().contains(info.id))

        let again = inboxFile("again.wav")
        try wav(seconds: 1, at: again)
        try WatchImport.keep(again, info: info)
        XCTAssertTrue(WatchImport.importWaiting().contains(info.id), "confirmed again, so the Watch can delete it")
        XCTAssertEqual(Library.loadAll().filter { $0.app == WatchImport.app && $0.startedAt == info.startedAt }.count, 1)
        XCTAssertEqual(waiting(info.id), [])
    }

    func testAFileThatCannotBeReadStaysAndIsNotConfirmed() throws {
        let info = WatchRecordingInfo(startedAt: Date(timeIntervalSince1970: 1_800_200_000), duration: 1)
        let broken = inboxFile("broken.wav")
        try Data("this is not audio".utf8).write(to: broken)
        let staged = Library.stagedIDs()
        try WatchImport.keep(broken, info: info)

        XCTAssertFalse(WatchImport.importWaiting().contains(info.id), "the Watch must keep its copy")
        XCTAssertEqual(waiting(info.id), [info], "and so does the iPhone, for the next try")
        XCTAssertEqual(Library.stagedIDs(), staged, "the half-written meeting is removed")
        XCTAssertFalse(Library.loadAll().contains { $0.startedAt == info.startedAt })

        // Leave the inbox clean for the other tests.
        for (left, audio) in WatchImport.waiting() where left.id == info.id {
            try FileManager.default.removeItem(at: audio)
            try FileManager.default.removeItem(at: WatchImport.inbox.appendingPathComponent("\(info.id.uuidString).json"))
        }
    }

    func testAWavCutShortGetsItsSizesBack() throws {
        let url = inboxFile("cut.wav")
        let samples = try cutShortWav(at: url)

        XCTAssertTrue(WatchImport.repairSizes(url))
        let fixed = try Data(contentsOf: url)
        func u32(_ at: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(fixed[at + i]) << (8 * UInt32(i)) }
            return v
        }
        XCTAssertEqual(u32(4), UInt32(fixed.count - 8))
        let dataAt = 12 + 24 + 8 + 12
        XCTAssertEqual(fixed[dataAt..<dataAt + 4], Data("data".utf8))
        XCTAssertEqual(u32(dataAt + 4), UInt32(samples.count))
        XCTAssertEqual(fixed.suffix(samples.count), samples, "the samples are not touched")
        XCTAssertFalse(WatchImport.repairSizes(url), "nothing left to repair")

        let text = inboxFile("notes.txt")
        try Data("not a wav at all".utf8).write(to: text)
        XCTAssertFalse(WatchImport.repairSizes(text))
    }

    func testAWatchRecordingCutShortIsStillImported() throws {
        let info = WatchRecordingInfo(startedAt: Date(timeIntervalSince1970: 1_800_300_000))
        let received = inboxFile("cut.wav")
        _ = try cutShortWav(at: received)
        try WatchImport.keep(received, info: info)

        XCTAssertTrue(WatchImport.importWaiting().contains(info.id))
        let m = try XCTUnwrap(Library.loadAll().first { $0.app == WatchImport.app && $0.startedAt == info.startedAt })
        XCTAssertEqual(m.status, .pending)
        XCTAssertEqual(m.duration ?? 0, 1, accuracy: 0.05)
    }

    func testTheLedgerRemembersTheNewestRecordings() {
        var ledger = WatchImport.Ledger()
        let ids = (0..<(WatchImport.Ledger.limit + 3)).map { _ in UUID() }
        for (n, id) in ids.enumerated() { ledger.record(id, meetingID: "m\(n)") }
        XCTAssertEqual(ledger.entries.count, WatchImport.Ledger.limit)
        XCTAssertNil(ledger.meetingID(for: ids[0]))
        XCTAssertEqual(ledger.meetingID(for: ids.last!), "m\(ids.count - 1)")
    }
}
