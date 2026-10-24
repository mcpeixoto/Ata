@testable import Ata
import XCTest

/// Every unnamed voice needs its own name on screen.
///
/// `Voice.displayName` is `name ?? "Voice \(number ?? 0)"`. A library written
/// before voices were numbered has `number == nil` on all of them, so every
/// unnamed voice read as "Voice 0" — the iPhone's "Who's this?" listed two
/// different people under one name, with nothing to tell them apart.
final class VoiceNumberingTests: XCTestCase {
    private var dir: URL!

    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and voice library, never the real ones
    }

    override func setUp() {
        super.setUp()
        dir = FilesTests.root.appendingPathComponent("numbering-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// Three unnamed voices, none numbered, as an Ata from before numbering left them.
    private let unnumbered = """
    [{"id":"11111111-1111-4111-8111-111111111111","centroid":[1,0,0],"observations":1,
      "meetingIDs":["a"],"firstSeen":"2026-10-20T10:00:00.000Z","lastSeen":"2026-10-20T10:00:00.000Z",
      "isMe":false},
     {"id":"22222222-2222-4222-8222-222222222222","centroid":[0,1,0],"observations":1,
      "meetingIDs":["b"],"firstSeen":"2026-10-21T10:00:00.000Z","lastSeen":"2026-10-21T10:00:00.000Z",
      "isMe":false},
     {"id":"33333333-3333-4333-8333-333333333333","centroid":[0,0,1],"observations":1,
      "meetingIDs":["c"],"firstSeen":"2026-10-22T10:00:00.000Z","lastSeen":"2026-10-22T10:00:00.000Z",
      "isMe":false}]
    """

    private func writeLegacy(_ json: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("voices.json"), atomically: true, encoding: .utf8)
    }

    func testEveryUnnamedVoiceGetsItsOwnName() throws {
        try writeLegacy(unnumbered)
        let lib = VoiceLibrary(directory: dir)

        XCTAssertEqual(lib.voices.count, 3)
        let names = lib.voices.map(\.displayName)
        XCTAssertEqual(Set(names).count, 3, "three voices, three names, got \(names)")
        XCTAssertFalse(names.contains("Voice 0"), "nothing should fall back to the placeholder: \(names)")
    }

    func testTheNumbersSurviveBeingReadBack() throws {
        try writeLegacy(unnumbered)
        let before = VoiceLibrary(directory: dir).voices.map { ($0.id, $0.displayName) }

        // A second open reads the per-voice files the first one wrote.
        let after = VoiceLibrary(directory: dir)
        for (id, name) in before {
            XCTAssertEqual(try XCTUnwrap(after.voice(id)).displayName, name,
                           "a voice should not be renamed by reopening the library")
        }
    }

    func testNumberingCarriesOnFromTheHighestAlreadyUsed() throws {
        // One voice already numbered 7; the other two have none.
        let mixed = """
        [{"id":"44444444-4444-4444-8444-444444444444","centroid":[1,0,0],"observations":1,
          "meetingIDs":["a"],"firstSeen":"2026-10-20T10:00:00.000Z","lastSeen":"2026-10-20T10:00:00.000Z",
          "isMe":false,"number":7},
         {"id":"55555555-5555-4555-8555-555555555555","centroid":[0,1,0],"observations":1,
          "meetingIDs":["b"],"firstSeen":"2026-10-21T10:00:00.000Z","lastSeen":"2026-10-21T10:00:00.000Z",
          "isMe":false},
         {"id":"66666666-6666-4666-8666-666666666666","centroid":[0,0,1],"observations":1,
          "meetingIDs":["c"],"firstSeen":"2026-10-22T10:00:00.000Z","lastSeen":"2026-10-22T10:00:00.000Z",
          "isMe":false}]
        """
        try writeLegacy(mixed)
        let lib = VoiceLibrary(directory: dir)

        let seven = try XCTUnwrap(lib.voice(try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))))
        XCTAssertEqual(seven.number, 7, "a voice that already had a number keeps it")

        let numbers = lib.voices.compactMap(\.number).sorted()
        XCTAssertEqual(numbers, [7, 8, 9], "the rest carry on from the highest in use, got \(numbers)")
    }

    /// A named voice never shows a number, so it does not matter whether it has one —
    /// but it must not be renamed by the backfill either.
    func testNamedVoicesAreLeftAlone() throws {
        let named = """
        [{"id":"77777777-7777-4777-8777-777777777777","name":"Rita","centroid":[1,0,0],"observations":1,
          "meetingIDs":["a"],"firstSeen":"2026-10-20T10:00:00.000Z","lastSeen":"2026-10-20T10:00:00.000Z",
          "isMe":false}]
        """
        try writeLegacy(named)
        let lib = VoiceLibrary(directory: dir)
        XCTAssertEqual(lib.voices.first?.displayName, "Rita")
    }
}
