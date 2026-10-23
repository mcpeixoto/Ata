@testable import Ata
import XCTest

/// Voices you don't want named, or don't want in transcripts at all: a TV in the
/// background, a meeting bot, someone who asked not to be recorded.
final class VoiceHidingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and voice library, never the real ones
    }

    private func libraryFile() -> URL {
        FilesTests.root.appendingPathComponent("voices-\(UUID().uuidString).json")
    }

    func testVoicesSavedBefore25StillLoad() throws {
        let file = libraryFile()
        try """
        [{"id":"6B3D2F4E-1A2B-4C3D-8E9F-0A1B2C3D4E5F","centroid":[1,0,0],"observations":3,
          "meetingIDs":["a","b"],"firstSeen":"2026-10-20T10:00:00.000Z","lastSeen":"2026-10-21T10:00:00.000Z",
          "isMe":false,"number":2}]
        """.write(to: file, atomically: true, encoding: .utf8)
        let library = VoiceLibrary(file: file)
        XCTAssertFalse(library.loadFailed)
        XCTAssertEqual(library.voices.count, 1)
        XCTAssertFalse(library.voices[0].isDismissed)
        XCTAssertFalse(library.voices[0].isExcluded)
        XCTAssertEqual(library.worthAsking.count, 1)
    }

    func testADismissedOrLeftOutVoiceIsNotAskedAbout() throws {
        let library = VoiceLibrary(file: libraryFile())
        for m in ["one", "two"] {
            library.assign([MeetingSpeaker(label: "S1", embedding: [1, 0, 0], seconds: 30, voiceID: nil),
                            MeetingSpeaker(label: "S2", embedding: [0, 1, 0], seconds: 30, voiceID: nil)],
                           meetingID: m)
        }
        XCTAssertEqual(library.worthAsking.count, 2)
        let (a, b) = (library.voices[0].id, library.voices[1].id)

        library.setDismissed(a, true)
        library.setExcluded(b, true)
        XCTAssertEqual(library.worthAsking.count, 0)
        try library.save()
        let reloaded = VoiceLibrary(file: library.file)
        XCTAssertTrue(try XCTUnwrap(reloaded.voice(a)).isDismissed, "saved")
        XCTAssertTrue(try XCTUnwrap(reloaded.voice(b)).isExcluded)

        library.setDismissed(a, false)
        XCTAssertEqual(library.worthAsking.map(\.id), [a], "asked again")
    }

    func testALeftOutVoiceDisappearsFromTheTranscriptAndComesBack() throws {
        let m = try Meeting.new(app: "Hiding \(UUID().uuidString.prefix(6))")
        let stored = StoredTranscript(segments: [
            .init(start: 0, end: 2_000, text: "Morning everyone", speaker: Speakers.me),
            .init(start: 2_500, end: 5_000, text: "And now the weather for the north", speaker: "S1"),
            .init(start: 6_000, end: 8_000, text: "Let's start with the budget", speaker: "S2"),
        ], coarse: false, summary: nil, engine: "local", model: "large-v3")
        try stored.save(to: m.storedTranscriptURL)

        // The default library: Speakers.leftOut reads it, under the temp support folder.
        let library = VoiceLibrary()
        let assigned = library.assign([MeetingSpeaker(label: "S1", embedding: [0, 0, 1], seconds: 3, voiceID: nil),
                                       MeetingSpeaker(label: "S2", embedding: [1, 1, 0], seconds: 2, voiceID: nil)],
                                      meetingID: m.id)
        try MeetingVoices(speakers: assigned, turns: []).save(for: m)
        let tv = try XCTUnwrap(assigned.first { $0.label == "S1" }?.voiceID)

        library.setExcluded(tv, true)
        try library.save()
        try Transcriber.rerender(m, myName: "Alex")
        var md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertFalse(md.contains("weather"), md)
        XCTAssertTrue(md.contains("Let's start with the budget"), md)
        XCTAssertTrue(md.contains("Morning everyone"), md)
        XCTAssertEqual(Speakers.leftOut(for: m), ["S1"])
        XCTAssertEqual(StoredTranscript.load(from: m.storedTranscriptURL), stored, "only hidden, never deleted")

        library.setExcluded(tv, false)
        try library.save()
        try Transcriber.rerender(m, myName: "Alex")
        md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("And now the weather for the north"), "put back")
    }

    func testExcludingLabelsLeavesEverythingElse() {
        let t = StoredTranscript(segments: [
            .init(start: 0, end: 1, text: "a", speaker: "S1"), .init(start: 2, end: 3, text: "b", speaker: Speakers.me),
        ], coarse: false, summary: nil, engine: "local", model: "m")
        XCTAssertEqual(t.excluding([]).segments.count, 2)
        XCTAssertEqual(t.excluding(["S1"]).segments.map(\.text), ["b"])
    }
}
