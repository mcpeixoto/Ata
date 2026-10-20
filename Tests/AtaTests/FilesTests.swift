@testable import Ata
import XCTest

/// Tests that touch disk. Every one of them works in a temporary folder that
/// `ATA_MEETINGS_DIR` points the app at, never in ~/Documents/Meetings.
final class FilesTests: XCTestCase {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ata-tests-\(UUID().uuidString)", isDirectory: true)

    override class func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("ATA_MEETINGS_DIR", root.path, 1)
        setenv("ATA_SUPPORT_DIR", root.appendingPathComponent("support").path, 1)
        precondition(Paths.meetingsDir.path == root.path, "tests must never touch real meetings")
        precondition(Paths.voicesDir.path.hasPrefix(root.path), "tests must never touch the real voice library")
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func wav(seconds: Int, at url: URL) throws {
        let samples = seconds * Int(WavWriter.sampleRate)
        var data = WavWriter.header(dataBytes: UInt32(samples * 2))
        data.append(Data((0..<samples * 2).map { UInt8($0 & 0xFF) }))
        try data.write(to: url)
    }

    // MARK: Splitting for upload

    func testLongRecordingsSplitIntoTimedPieces() throws {
        let source = Self.root.appendingPathComponent("long.wav")
        try wav(seconds: 25, at: source)
        let chunks = try AudioFiles.split(source, maxSeconds: 10, into: Self.root.appendingPathComponent("chunks"))
        defer { AudioFiles.cleanUp(chunks) }

        XCTAssertEqual(chunks.map(\.offsetMs), [0, 10_000, 20_000])
        XCTAssertEqual(chunks.map { WavWriter.duration(of: $0.url) }, [10, 10, 5])
        XCTAssertTrue(chunks.allSatisfy(\.temporary))

        // The pieces put back together are the original audio, byte for byte.
        let original = try Data(contentsOf: source).dropFirst(44)
        let joined = try chunks.reduce(Data()) { $0 + (try Data(contentsOf: $1.url)).dropFirst(44) }
        XCTAssertEqual(original, joined)
    }

    func testShortRecordingsAreNotCopied() throws {
        let source = Self.root.appendingPathComponent("short.wav")
        try wav(seconds: 3, at: source)
        let chunks = try AudioFiles.split(source, maxSeconds: 10, into: Self.root.appendingPathComponent("chunks2"))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].url, source)
        XCTAssertFalse(chunks[0].temporary)
    }

    // MARK: Versions

    func testTranscribingAgainKeepsTheOldTranscript() throws {
        var m = try Meeting.new(app: "Zoom")
        try "first".write(to: m.transcriptURL, atomically: true, encoding: .utf8)
        m.transcriptions = [TranscriptionRecord(engine: "local", model: "large-v3-turbo",
                                                finishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                audioSeconds: 60, processingSeconds: 5, costUSD: 0, words: 1,
                                                mySpeechSeconds: 1, othersSpeechSeconds: 1, archivedAs: nil)]

        let name = try XCTUnwrap(try Transcriber.archivePrevious(of: m))
        XCTAssertTrue(name.hasSuffix(" large-v3-turbo.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.transcriptURL.path))
        XCTAssertEqual(try String(contentsOf: m.versionsDir.appendingPathComponent(name), encoding: .utf8), "first")

        // A second archive with the same timestamp and model must not overwrite the first.
        try "second".write(to: m.transcriptURL, atomically: true, encoding: .utf8)
        let other = try XCTUnwrap(try Transcriber.archivePrevious(of: m))
        XCTAssertNotEqual(name, other)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: m.versionsDir.path).count, 2)
    }

    func testNothingToArchiveIsFine() throws {
        let m = try Meeting.new(app: "Slack")
        XCTAssertNil(try Transcriber.archivePrevious(of: m))
    }

    // MARK: Backfill and insights

    func testOldTranscriptsAreReadForTheHistory() throws {
        var m = try Meeting.new(app: "Teams")
        m.status = .done
        m.duration = 600
        try """
        # Teams — today

        **[00:00] Alex:** one two three four

        **[00:05] Others:** five six

        **Others:** seven
        """.write(to: m.transcriptURL, atomically: true, encoding: .utf8)

        let record = try XCTUnwrap(Backfill.record(for: m, myName: "Alex"))
        XCTAssertEqual(record.words, 7)
        XCTAssertEqual(record.mySpeechSeconds, 4 / 2.5, accuracy: 1e-9)
        XCTAssertEqual(record.othersSpeechSeconds, 3 / 2.5, accuracy: 1e-9)
        XCTAssertEqual(record.costUSD, 0)
    }

    func testInsightsAddUpAndOnlyCountTheCurrentTranscript() {
        // A Wednesday at noon, so both meetings land in the same week wherever the week starts.
        let now = Date(timeIntervalSince1970: 1_792_584_000)
        func rec(_ model: String, _ engine: String, _ cost: Double, _ ago: Double, words: Int) -> TranscriptionRecord {
            TranscriptionRecord(engine: engine, model: model, finishedAt: now.addingTimeInterval(-ago),
                                audioSeconds: 1_200, processingSeconds: 1, costUSD: cost, words: words,
                                mySpeechSeconds: 100, othersSpeechSeconds: 300, archivedAs: nil)
        }
        var a = Meeting(id: "a", startedAt: now.addingTimeInterval(-3_600), endedAt: nil, duration: 600,
                        app: "Zoom", status: .done, error: nil)
        a.transcriptions = [rec("whisper-1", "openai", 0.12, 3_000, words: 900),
                            rec("large-v3", "local", 0, 1_000, words: 1_000)]
        var b = Meeting(id: "b", startedAt: now.addingTimeInterval(-7_200), endedAt: nil, duration: 1_200,
                        app: "Slack", status: .done, error: nil)
        b.transcriptions = [rec("large-v3", "local", 0, 6_000, words: 500)]

        let i = Insights.compute([a, b], myName: "Alex", now: now)
        XCTAssertEqual(i.meetings, 2)
        XCTAssertEqual(i.recordedSeconds, 1_800)
        XCTAssertEqual(i.words, 1_500)                     // current transcripts only
        XCTAssertEqual(i.spentTotal, 0.12, accuracy: 1e-9)  // every run that cost money
        XCTAssertEqual(i.mySpeech, 200)
        XCTAssertEqual(i.myShare, 0.25, accuracy: 1e-9)
        XCTAssertEqual(i.timeline.count, 3)
        XCTAssertEqual(i.timeline.filter { !$0.isCurrent }.map(\.record.model), ["whisper-1"])
        XCTAssertEqual(i.weeks.count, Insights.weeksShown)
        XCTAssertEqual(i.weeks.last?.meetings, 2)
        XCTAssertEqual(i.apps.map(\.name), ["Slack", "Zoom"])
    }
}

final class RerenderTests: XCTestCase {
    static let root = FilesTests.root

    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    func testNamingAVoiceRewritesTheTranscriptWithoutTranscribingAgain() throws {
        var m = try Meeting.new(app: "Zoom")
        m.duration = 120
        let stored = StoredTranscript(segments: [
            .init(start: 0, end: 2_000, text: "Hello everyone", speaker: Speakers.me),
            .init(start: 2_500, end: 5_000, text: "Hi, thanks for having me", speaker: "S1"),
            .init(start: 6_000, end: 8_000, text: "Shall we start", speaker: "S2"),
        ], coarse: false, summary: "**Overview** — a greeting.", engine: "local", model: "large-v3")
        try stored.save(to: m.storedTranscriptURL)
        XCTAssertEqual(StoredTranscript.load(from: m.storedTranscriptURL), stored)

        // Before any voice is known: generic labels.
        try Transcriber.rerender(m, myName: "Alex")
        var md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("**[00:00] Alex:** Hello everyone"))
        XCTAssertTrue(md.contains("**[00:02] Speaker 1:** Hi, thanks for having me"))
        XCTAssertTrue(md.contains("**[00:06] Speaker 2:** Shall we start"))
        XCTAssertTrue(md.contains("## Summary"), "the summary survives a re-render")
        XCTAssertTrue(md.contains("Participants: Alex, Speaker 1, Speaker 2"))

        // S1 is matched to a voice, and that voice gets a name.
        let library = VoiceLibrary()
        let assigned = library.assign([MeetingSpeaker(label: "S1", embedding: [1, 0, 0], seconds: 3, voiceID: nil)],
                                      meetingID: m.id)
        library.rename(try XCTUnwrap(assigned[0].voiceID), to: "Rita")
        try library.save()
        try MeetingVoices(speakers: assigned, turns: []).save(for: m)

        try Transcriber.rerender(m, myName: "Alex")
        md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("**[00:02] Rita:** Hi, thanks for having me"))
        XCTAssertTrue(md.contains("**[00:06] Speaker 2:** Shall we start"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.versionsDir.path), "a rename is not a new version")
    }
}
