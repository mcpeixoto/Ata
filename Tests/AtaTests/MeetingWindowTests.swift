@testable import Ata
import AppKit
import AVFoundation
import XCTest

/// meeting.mp3: both tracks mixed into one file. Works in the same temporary
/// meetings folder as `FilesTests`, never in ~/Documents/Meetings.
final class MergedAudioTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    /// A meeting folder of its own, so tests never share tracks.
    private func meeting() throws -> Meeting {
        try Meeting.new(app: "Merge \(UUID().uuidString.prefix(8))")
    }

    /// `seconds` of a sine tone as Ata records it: 16 kHz mono 16-bit WAV.
    private func tone(_ seconds: Double, hz: Double, amplitude: Double = 8000, at url: URL) throws {
        let samples = Int(seconds * WavWriter.sampleRate)
        var data = WavWriter.header(dataBytes: UInt32(samples * 2))
        for i in 0..<samples {
            let v = Int16(amplitude * sin(2 * .pi * hz * Double(i) / WavWriter.sampleRate))
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    private func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func peak(of url: URL) throws -> Int {
        let reader = try PCM16Reader(url)
        var peak = 0
        while let block = try reader.next() {
            peak = max(peak, block.map { abs(Int($0)) }.max() ?? 0)
        }
        return peak
    }

    func testMixingAddsTracksAndAShorterOneCountsAsSilence() {
        XCTAssertEqual(MergedAudio.mix([[1_000, -1_000, 7], [500]]), [1_500, -1_000, 7])
        XCTAssertEqual(MergedAudio.mix([[3, 4]]), [3, 4])
        XCTAssertEqual(MergedAudio.mix([]), [])
        XCTAssertEqual(MergedAudio.mix([[], []]), [])
    }

    func testTwoLoudVoicesClipInsteadOfWrappingAround() {
        XCTAssertEqual(MergedAudio.mix([[30_000, -30_000], [30_000, -30_000]]), [Int16.max, Int16.min])
    }

    func testBothTracksBecomeOneMP3AsLongAsTheLongerTrack() throws {
        let m = try meeting()
        try tone(3, hz: 440, at: m.micURL)
        try tone(5, hz: 220, at: m.systemURL)
        let micBytes = Paths.fileSize(m.micURL)
        let systemBytes = Paths.fileSize(m.systemURL)

        try MergedAudio.write(m)

        XCTAssertTrue(m.hasMergedAudio)
        XCTAssertEqual(try seconds(of: m.mergedAudioURL), 5, accuracy: 0.25)
        XCTAssertGreaterThan(try peak(of: m.mergedAudioURL), 2_000, "the MP3 carries the voices, not silence")
        XCTAssertLessThan(Paths.fileSize(m.mergedAudioURL), (micBytes + systemBytes) / 4,
                          "48 kbps is several times smaller than the two WAVs")

        XCTAssertEqual(Paths.fileSize(m.micURL), micBytes, "the tracks are never touched")
        XCTAssertEqual(Paths.fileSize(m.systemURL), systemBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.mergedAudioURL.path + ".partial"))
        XCTAssertEqual(m.audioBytes, micBytes + systemBytes + Paths.fileSize(m.mergedAudioURL))
    }

    func testAMeetingWithOnlyCompressedSystemAudioStillMerges() async throws {
        let m = try meeting()
        try tone(2, hz: 330, at: m.systemURL)
        let compressed = await AudioFiles.compressToM4A(m.systemURL)
        XCTAssertNotNil(compressed)
        XCTAssertNil(m.micAudioURL)

        try MergedAudio.write(m)
        XCTAssertEqual(try seconds(of: m.mergedAudioURL), 2, accuracy: 0.25)
    }

    func testWritingAgainReplacesTheOldMP3() throws {
        let m = try meeting()
        try tone(1, hz: 440, at: m.micURL)
        try MergedAudio.write(m)
        try tone(3, hz: 440, at: m.micURL)
        try MergedAudio.write(m)
        XCTAssertEqual(try seconds(of: m.mergedAudioURL), 3, accuracy: 0.25)
    }

    func testADamagedTrackLeavesNoMP3AndKeepsTheTracks() throws {
        let m = try meeting()
        try tone(2, hz: 440, at: m.micURL)
        let damaged = m.dir.appendingPathComponent("system.m4a")
        try Data(repeating: 7, count: 4096).write(to: damaged)

        XCTAssertThrowsError(try MergedAudio.write(m))
        XCTAssertFalse(m.hasMergedAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.mergedAudioURL.path + ".partial"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
    }

    func testNoTracksIsAnError() throws {
        let m = try meeting()
        XCTAssertThrowsError(try MergedAudio.write(tracks: [], to: m.mergedAudioURL))
        XCTAssertFalse(m.hasMergedAudio)
    }
}

final class MeetingNotesTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    private func meeting() throws -> Meeting {
        try Meeting.new(app: "Notes \(UUID().uuidString.prefix(8))")
    }

    func testYourNotesAreSavedAndClearingThemRemovesTheFile() throws {
        let m = try meeting()
        XCTAssertEqual(MeetingNotes.load(for: m), "")

        try MeetingNotes.save("Follow up with Rita\n", for: m)
        XCTAssertEqual(MeetingNotes.load(for: m), "Follow up with Rita\n")

        try MeetingNotes.save("  \n", for: m)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.notesURL.path))
        XCTAssertEqual(MeetingNotes.load(for: m), "")
    }

    func testNotesWrittenLaterGoIntoTheTranscriptAndTheCost() throws {
        var m = try meeting()
        m.status = .done
        m.transcriptions = [TranscriptionRecord(engine: "local", model: "large-v3", finishedAt: Date(),
                                                audioSeconds: 120, processingSeconds: 9, costUSD: 0, words: 8,
                                                mySpeechSeconds: 40, othersSpeechSeconds: 50, archivedAs: nil)]
        Library.save(m)
        try StoredTranscript(segments: [
            .init(start: 0, end: 2_000, text: "Shall we ship on Friday?", speaker: Speakers.me),
            .init(start: 2_500, end: 4_000, text: "Yes, Friday.", speaker: Speakers.others),
        ], coarse: false, summary: nil, engine: "local", model: "large-v3").save(to: m.storedTranscriptURL)
        try Transcriber.rerender(m, myName: "Alex")
        XCTAssertFalse(try String(contentsOf: m.transcriptURL, encoding: .utf8).contains("## Summary"))

        let updated = try MeetingNotes.addSummary("**Decisions**\n- Ship on Friday", costUSD: 0.002,
                                                  to: m, myName: "Alex")

        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("## Summary\n\n**Decisions**\n- Ship on Friday"))
        XCTAssertTrue(md.contains("**[00:00] Alex:** Shall we ship on Friday?"), "the transcript itself is unchanged")
        XCTAssertEqual(StoredTranscript.load(from: m.storedTranscriptURL)?.summary, "**Decisions**\n- Ship on Friday")
        XCTAssertEqual(updated.latestTranscription?.costUSD ?? 0, 0.002, accuracy: 1e-9)
        XCTAssertEqual(Library.load(m.id)?.latestTranscription?.costUSD ?? 0, 0.002, accuracy: 1e-9)
        XCTAssertEqual(Library.load(m.id)?.transcriptions?.count, 1, "notes are not a new transcription")
        XCTAssertFalse(FileManager.default.fileExists(atPath: m.versionsDir.path), "nothing is archived")
    }

    func testNotesNeedAStoredTranscript() throws {
        let m = try meeting()
        XCTAssertThrowsError(try MeetingNotes.addSummary("Anything", costUSD: 0, to: m, myName: "Alex"))
    }

    func testTheSummaryReadsWithBulletsInTheApp() {
        let shown = MeetingNotes.display("**Decisions**\n- Ship on Friday\n- Tell support")
        XCTAssertEqual(String(shown.characters), "Decisions\n•  Ship on Friday\n•  Tell support")
    }

    func testAMeetingLoadsByItsFolderName() throws {
        let m = try meeting()
        Library.save(m)
        XCTAssertEqual(Library.load(m.id)?.id, m.id)
        XCTAssertNil(Library.load("no such meeting"))
    }
}

final class TranscriptBlocksTests: XCTestCase {
    func testOneSpeakersLinesJoinUntilSomeoneElseSpeaksOrTheyPause() {
        let t = StoredTranscript(segments: [
            .init(start: 3_000, end: 4_000, text: "and then", speaker: Speakers.me),
            .init(start: 0, end: 2_000, text: "So", speaker: Speakers.me),
            .init(start: 4_500, end: 6_000, text: "Right.", speaker: "S1"),
            .init(start: 6_200, end: 7_000, text: "Next", speaker: Speakers.me),
            .init(start: 12_000, end: 13_000, text: "Later", speaker: Speakers.me),
        ], coarse: false, summary: nil, engine: "local", model: "large-v3")

        let blocks = Transcriber.blocks(t)
        XCTAssertEqual(blocks.map(\.text), ["So and then", "Right.", "Next", "Later"])
        XCTAssertEqual(blocks.map(\.start), [0, 4_500, 6_200, 12_000])
        XCTAssertEqual(blocks[0].end, 4_000)
    }
}

final class MenuIconTests: XCTestCase {
    func testUnknownPreferencesFallBackToTheDefaults() {
        XCTAssertEqual(MenuIcon.Style(symbol: "sparkles", tint: nil, timer: true, pulse: false), MenuIcon.Style())
        XCTAssertEqual(MenuIcon.Style().symbol, .dot)
        XCTAssertEqual(MenuIcon.Style().tint, .monochrome, "out of the box the icon looks the way it always has")
    }

    func testStoredPreferencesAreRead() {
        XCTAssertEqual(MenuIcon.Style(symbol: "mic", tint: "red", timer: false, pulse: true),
                       MenuIcon.Style(symbol: .mic, tint: .red, timer: false, pulse: true))
    }

    func testThePulseBreathesBetween35PercentAndFull() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(MenuIcon.pulseOpacity(at: start), 1, accuracy: 1e-9)
        XCTAssertEqual(MenuIcon.pulseOpacity(at: start.addingTimeInterval(0.8)), 0.35, accuracy: 1e-9)
        XCTAssertEqual(MenuIcon.pulseOpacity(at: start.addingTimeInterval(1.6)), 1, accuracy: 1e-6)
        for i in 0..<200 {
            let o = MenuIcon.pulseOpacity(at: start.addingTimeInterval(Double(i) * 0.037))
            XCTAssertTrue((0.35 - 1e-9...1 + 1e-9).contains(o))
        }
    }

    func testOnlyTheMonochromeIconIsATemplate() {
        XCTAssertTrue(MenuIcon.image(MenuIcon.Style(tint: .monochrome)).isTemplate)
        XCTAssertTrue(MenuIcon.image(MenuIcon.Style(tint: .monochrome), opacity: 0.5).isTemplate)
        XCTAssertFalse(MenuIcon.image(MenuIcon.Style(tint: .red)).isTemplate,
                       "a template would be repainted in the menu bar's colour")
        XCTAssertFalse(MenuIcon.image(MenuIcon.Style(tint: .accent), opacity: 0.5).isTemplate)
    }

    func testEverySymbolExists() {
        for symbol in MenuIcon.Symbol.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol.systemName, accessibilityDescription: nil), symbol.rawValue)
            XCTAssertGreaterThan(MenuIcon.image(MenuIcon.Style(symbol: symbol)).size.width, 0)
        }
    }
}

/// Older meetings and sharing: what gets an MP3, and what the share sheet is handed.
final class MeetingSharingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    private func meeting(_ app: String = "Share") throws -> Meeting {
        try Meeting.new(app: "\(app) \(UUID().uuidString.prefix(8))")
    }

    private func tone(_ seconds: Double, at url: URL) throws {
        let samples = Int(seconds * WavWriter.sampleRate)
        var data = WavWriter.header(dataBytes: UInt32(samples * 2))
        for i in 0..<samples {
            let v = Int16(8000 * sin(2 * .pi * 440 * Double(i) / WavWriter.sampleRate))
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    private var scratch: URL {
        FilesTests.root.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
    }

    func testOnlyMeetingsWithTracksAndNoMP3AreBackfilled() throws {
        var old = try meeting("Old")              // recorded before 2.4: tracks, no MP3
        old.status = .done
        try tone(1, at: old.micURL)
        var merged = try meeting("Merged")        // already has its MP3
        merged.status = .done
        try tone(1, at: merged.micURL)
        try MergedAudio.write(merged)
        var gone = try meeting("Gone")            // audio deleted by retention
        gone.status = .done
        var live = try meeting("Live")            // still recording
        live.status = .recording
        try tone(1, at: live.micURL)

        let picked = MergedAudio.missing(in: [old, merged, gone, live]).map(\.id)
        XCTAssertEqual(picked, [old.id])
    }

    func testSharingAMeetingFromBefore24MixesItsTracksWithoutTouchingTheFolder() throws {
        let m = try meeting()
        try tone(2, at: m.micURL)
        try tone(2, at: m.systemURL)
        let out = scratch.appendingPathComponent(MeetingSharing.name(for: m) + ".mp3")

        try MeetingSharing.audio(of: m, to: out, link: true)

        XCTAssertGreaterThan(Paths.fileSize(out), 0)
        XCTAssertFalse(m.hasMergedAudio, "sharing makes a copy for the share sheet, not meeting.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: m.micURL.path))
    }

    func testSharingUsesMeetingMP3WhenThereIsOne() throws {
        let m = try meeting()
        try tone(1, at: m.micURL)
        try MergedAudio.write(m)
        let original = try Data(contentsOf: m.mergedAudioURL)

        for link in [true, false] {
            let out = scratch.appendingPathComponent("Shared.mp3")
            try MeetingSharing.audio(of: m, to: out, link: link)
            XCTAssertEqual(try Data(contentsOf: out), original)
            try MeetingSharing.audio(of: m, to: out, link: link) // again, over the first copy
            XCTAssertEqual(try Data(contentsOf: out), original)
        }
        XCTAssertEqual(try Data(contentsOf: m.mergedAudioURL), original, "the meeting's own MP3 is untouched")
    }

    func testTheTranscriptIsSharedUnderTheMeetingsName() throws {
        let m = try meeting()
        let dir = scratch
        XCTAssertNil(try MeetingSharing.transcript(of: m, in: dir), "nothing to share before a transcript exists")

        try "# Zoom\n".write(to: m.transcriptURL, atomically: true, encoding: .utf8)
        let shared = try XCTUnwrap(MeetingSharing.transcript(of: m, in: dir))
        XCTAssertEqual(shared.lastPathComponent, MeetingSharing.name(for: m) + ".md")
        XCTAssertEqual(try String(contentsOf: shared, encoding: .utf8), "# Zoom\n")
    }

    func testShareNamesNeverBecomePaths() throws {
        var m = try meeting()
        m.app = "Teams: Work/Home"
        let name = MeetingSharing.name(for: m)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasPrefix("Teams- Work-Home "))
    }
}
