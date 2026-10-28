import XCTest

// ShareInbox.swift is compiled straight into this bundle: the inbox the share
// extension fills and the app drains, tested on a temporary folder.
final class ShareInboxTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private struct Broken: LocalizedError {
        var errorDescription: String? { "broken" }
    }

    private var inbox: URL { root.appendingPathComponent("Inbox", isDirectory: true) }

    /// A file somewhere else, as the share sheet hands it over.
    private func shared(_ name: String, bytes: String = "audio") throws -> URL {
        let dir = root.appendingPathComponent("from-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + seconds)
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? []).sorted()
    }

    // MARK: Sidecar

    func testTheSidecarRoundTrips() throws {
        let item = InboxItem(file: "A.m4a", originalName: "Call with Ana.m4a", date: date(0), attempts: 2)
        XCTAssertEqual(try ShareInbox.decode(ShareInbox.encode(item)), item)
    }

    func testASidecarWithoutAttemptsHasNone() throws {
        let json = #"{"date":"2026-09-21T12:00:00Z","file":"A.m4a","originalName":"Memo.m4a"}"#
        let item = try ShareInbox.decode(Data(json.utf8))
        XCTAssertEqual(item.attempts, 0)
        XCTAssertEqual(item.originalName, "Memo.m4a")
    }

    func testTheSidecarIsNamedAfterItsAudio() {
        XCTAssertEqual(ShareInbox.sidecarName(for: "A.m4a"), "A.m4a.json")
    }

    // MARK: Names

    func testTheSuggestedNameKeepsTheFilesExtension() {
        let file = URL(fileURLWithPath: "/tmp/x/7F2A.m4a")
        XCTAssertEqual(ShareInbox.originalName(suggested: "Call with Ana", file: file), "Call with Ana.m4a")
        XCTAssertEqual(ShareInbox.originalName(suggested: "Call with Ana.M4A", file: file), "Call with Ana.M4A")
        XCTAssertEqual(ShareInbox.originalName(suggested: nil, file: file), "7F2A.m4a")
        XCTAssertEqual(ShareInbox.originalName(suggested: "  ", file: file), "7F2A.m4a")
        XCTAssertFalse(ShareInbox.originalName(suggested: "a/b", file: file).contains("/"))
    }

    // MARK: Adding

    func testAddingCopiesTheFileAndLeavesTheSourceAlone() throws {
        let source = try shared("Memo.m4a", bytes: "the recording")
        let item = try ShareInbox.add(source, originalName: "Memo.m4a", date: date(0), to: inbox)

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "the recording", "the source is only read")
        XCTAssertEqual(files(), [item.file, ShareInbox.sidecarName(for: item.file)].sorted())
        XCTAssertTrue(item.file.hasSuffix(".m4a"))
        XCTAssertEqual(try String(contentsOf: inbox.appendingPathComponent(item.file), encoding: .utf8), "the recording")

        let pending = ShareInbox.pending(in: inbox)
        XCTAssertEqual(pending.map(\.item), [item])
        XCTAssertEqual(pending.first?.audio.lastPathComponent, item.file)
    }

    func testTwoSharesOfOneFileAreTwoItems() throws {
        let source = try shared("Memo.m4a")
        let first = try ShareInbox.add(source, originalName: "Memo.m4a", date: date(0), to: inbox)
        let second = try ShareInbox.add(source, originalName: "Memo.m4a", date: date(0), to: inbox)
        XCTAssertNotEqual(first.file, second.file)
        XCTAssertEqual(ShareInbox.pending(in: inbox).count, 2)
    }

    func testAnEmptyOrMissingInboxHasNothing() throws {
        XCTAssertEqual(ShareInbox.pending(in: inbox), [])
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        XCTAssertEqual(ShareInbox.pending(in: inbox), [])
    }

    // MARK: Pending

    func testOnlyWholeItemsArePending() throws {
        let whole = try ShareInbox.add(try shared("Whole.m4a"), originalName: "Whole.m4a", date: date(0), to: inbox)
        // Still being copied: audio, no sidecar yet.
        try Data("half".utf8).write(to: inbox.appendingPathComponent("Copying.m4a"))
        // A sidecar whose audio is gone.
        let orphan = InboxItem(file: "Gone.m4a", originalName: "Gone.m4a", date: date(1))
        try ShareInbox.encode(orphan).write(to: inbox.appendingPathComponent(ShareInbox.sidecarName(for: orphan.file)))
        // A sidecar that names some other file.
        try Data("audio".utf8).write(to: inbox.appendingPathComponent("Other.m4a"))
        let elsewhere = InboxItem(file: "../Other.m4a", originalName: "Other.m4a", date: date(2))
        try ShareInbox.encode(elsewhere).write(to: inbox.appendingPathComponent("Other.m4a.json"))
        // Not JSON at all.
        try Data("audio".utf8).write(to: inbox.appendingPathComponent("Junk.m4a"))
        try Data("{".utf8).write(to: inbox.appendingPathComponent("Junk.m4a.json"))

        XCTAssertEqual(ShareInbox.pending(in: inbox).map(\.item), [whole])
    }

    func testOldestFirstThenByName() throws {
        let late = try ShareInbox.add(try shared("C.m4a"), originalName: "C.m4a", date: date(60), to: inbox)
        let earlyB = try ShareInbox.add(try shared("B.m4a"), originalName: "B.m4a", date: date(0), to: inbox)
        let earlyA = try ShareInbox.add(try shared("A.m4a"), originalName: "A.m4a", date: date(0), to: inbox)
        let first = try ShareInbox.add(try shared("Z.m4a"), originalName: "Z.m4a", date: date(-60), to: inbox)

        XCTAssertEqual(ShareInbox.pending(in: inbox).map(\.item), [first, earlyA, earlyB, late])
    }

    // MARK: Draining

    func testDrainImportsOldestFirstAndRemovesEachAfterItsMeeting() throws {
        let b = try ShareInbox.add(try shared("B.m4a"), originalName: "B.m4a", date: date(10), to: inbox)
        let a = try ShareInbox.add(try shared("A.m4a"), originalName: "A.m4a", date: date(0), to: inbox)

        var seen: [String] = []
        let report = ShareInbox.drain(ShareInbox.pending(in: inbox)) { entry in
            // While its meeting is made, the copy is still there.
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.audio.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.sidecar.path))
            seen.append(entry.item.file)
        }

        XCTAssertEqual(seen, [a.file, b.file])
        XCTAssertEqual(report.imported, ["A.m4a", "B.m4a"])
        XCTAssertEqual(report.failed, [])
        XCTAssertEqual(files(), [])
    }

    func testAFailedImportKeepsTheAudioAndTheRestGoOn() throws {
        let bad = try ShareInbox.add(try shared("Bad.m4a", bytes: "keep me"), originalName: "Bad.m4a",
                                     date: date(0), to: inbox)
        let good = try ShareInbox.add(try shared("Good.m4a"), originalName: "Good.m4a", date: date(10), to: inbox)

        let report = ShareInbox.drain(ShareInbox.pending(in: inbox)) { entry in
            if entry.item.file == bad.file { throw Broken() }
        }

        XCTAssertEqual(report.imported, ["Good.m4a"])
        XCTAssertEqual(report.failed, [ShareInbox.Report.Failure(name: "Bad.m4a", message: "broken")])
        XCTAssertEqual(files(), [bad.file, ShareInbox.sidecarName(for: bad.file)].sorted())
        XCTAssertFalse(files().contains(good.file))
        XCTAssertEqual(try String(contentsOf: inbox.appendingPathComponent(bad.file), encoding: .utf8), "keep me")
        XCTAssertEqual(ShareInbox.pending(in: inbox).map(\.item.attempts), [1])
    }

    func testAnItemThatKeepsFailingIsLeftAloneButKept() throws {
        let bad = try ShareInbox.add(try shared("Bad.m4a"), originalName: "Bad.m4a", date: date(0), to: inbox)
        for _ in 0..<ShareInbox.maxAttempts {
            _ = ShareInbox.drain(ShareInbox.pending(in: inbox)) { _ in throw Broken() }
        }

        XCTAssertEqual(ShareInbox.pending(in: inbox), [], "not tried again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent(bad.file).path),
                      "audio is never deleted on a failure")
    }

    func testRemovingTakesTheSidecarAndTheAudio() throws {
        _ = try ShareInbox.add(try shared("A.m4a"), originalName: "A.m4a", date: date(0), to: inbox)
        let entry = try XCTUnwrap(ShareInbox.pending(in: inbox).first)
        ShareInbox.remove(entry)
        XCTAssertEqual(files(), [])
    }
}
