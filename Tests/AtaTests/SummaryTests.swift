@testable import Ata
import XCTest

/// Summaries on this Mac: the chunks the on-device model reads, the Markdown Ata
/// writes from its answer, and which engine gets the job.
final class SummaryChunkTests: XCTestCase {
    private let transcript = (1...200)
        .map { "**[00:\(String(format: "%02d", $0 % 60))] Alex:** line number \($0) of the meeting, said out loud." }
        .joined(separator: "\n") + "\n"

    func testChunksStayUnderTheLimit() {
        let chunks = SummaryChunks.split(transcript, maxCharacters: 500)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 500) }
    }

    func testChunksCoverTheTextExactlyOnceInOrder() {
        XCTAssertEqual(SummaryChunks.split(transcript, maxCharacters: 500).joined(), transcript)
        XCTAssertEqual(SummaryChunks.split(transcript).joined(), transcript)
    }

    func testChunksNeverCutALine() {
        let chunks = SummaryChunks.split(transcript, maxCharacters: 500)
        for chunk in chunks.dropLast() { XCTAssertTrue(chunk.hasSuffix("\n"), chunk) }
        let lines = Set(transcript.split(separator: "\n").map(String.init))
        for chunk in chunks {
            for line in chunk.split(separator: "\n") { XCTAssertTrue(lines.contains(String(line)), String(line)) }
        }
    }

    func testAShortTranscriptIsOneChunk() {
        XCTAssertEqual(SummaryChunks.split("one\ntwo\n"), ["one\ntwo\n"])
        XCTAssertEqual(SummaryChunks.split(""), [])
    }

    func testALineLongerThanTheLimitIsCut() {
        let long = String(repeating: "word ", count: 50) // 250 characters, no line break
        let text = "before\n" + long + "\nafter\n"
        let chunks = SummaryChunks.split(text, maxCharacters: 100)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks { XCTAssertLessThanOrEqual(chunk.count, 100) }
        XCTAssertEqual(chunks.first, "before\n", "the short line before is not glued to the cut one")
        XCTAssertEqual(chunks[1], String(long.prefix(100)))
    }
}

final class SummaryMarkdownTests: XCTestCase {
    func testTheShapeMatchesTheOpenAISummary() {
        let md = SummaryMarkdown.render(
            overview: "The team planned the launch.",
            decisions: ["Ship on Friday", "Keep the price"],
            actionItems: ["Alex: write the release notes"],
            openQuestions: ["Who tells support?"])
        XCTAssertEqual(md, """
        **Overview** — The team planned the launch.

        **Decisions**
        - Ship on Friday
        - Keep the price

        **Action items**
        - Alex: write the release notes

        **Open questions**
        - Who tells support?
        """)
    }

    func testEmptySectionsAreLeftOut() {
        let md = SummaryMarkdown.render(overview: "A short catch-up.", decisions: [],
                                        actionItems: ["Sam: book the room"], openQuestions: ["  ", ""])
        XCTAssertEqual(md, "**Overview** — A short catch-up.\n\n**Action items**\n- Sam: book the room")
    }

    func testAnEmptyOverviewIsLeftOut() {
        XCTAssertEqual(SummaryMarkdown.render(overview: " ", decisions: ["Ship it"], actionItems: [], openQuestions: []),
                       "**Decisions**\n- Ship it")
        XCTAssertEqual(SummaryMarkdown.render(overview: "", decisions: [], actionItems: [], openQuestions: []), "")
    }

    func testTheModelsOwnBulletsAndLineBreaksAreTidied() {
        let md = SummaryMarkdown.render(overview: "First line.\nSecond line.", decisions: ["- Ship it", "• Tell Sam"],
                                        actionItems: [], openQuestions: [])
        XCTAssertEqual(md, "**Overview** — First line. Second line.\n\n**Decisions**\n- Ship it\n- Tell Sam")
    }
}

final class SummaryEngineTests: XCTestCase {
    private func engine(_ preference: String, apple: Bool, key: Bool) -> SummaryEngine? {
        Summarizer.engine(preference: preference, appleAvailable: apple, hasOpenAIKey: key)
    }

    func testAutoPrefersThisMacThenOpenAI() {
        XCTAssertEqual(engine("auto", apple: true, key: true), .apple)
        XCTAssertEqual(engine("auto", apple: true, key: false), .apple)
        XCTAssertEqual(engine("auto", apple: false, key: true), .openAI)
        XCTAssertNil(engine("auto", apple: false, key: false))
    }

    func testChoosingThisMacNeverMeansOpenAI() {
        XCTAssertEqual(engine("apple", apple: true, key: true), .apple)
        XCTAssertEqual(engine("apple", apple: true, key: false), .apple)
        XCTAssertNil(engine("apple", apple: false, key: true))
        XCTAssertNil(engine("apple", apple: false, key: false))
    }

    func testChoosingOpenAINeedsAKey() {
        XCTAssertEqual(engine("openai", apple: true, key: true), .openAI)
        XCTAssertNil(engine("openai", apple: true, key: false))
        XCTAssertEqual(engine("openai", apple: false, key: true), .openAI)
        XCTAssertNil(engine("openai", apple: false, key: false))
    }

    func testAnUnknownPreferenceActsLikeAuto() {
        XCTAssertEqual(engine("", apple: true, key: true), .apple)
        XCTAssertEqual(engine("something", apple: false, key: true), .openAI)
    }

    func testOptionsDefaultToAuto() {
        let options = TranscribeOptions(engine: .local, myName: "Alex", language: "auto", openAIModel: "whisper-1",
                                        localModel: "large-v3", summarize: true, summaryModel: "gpt-4o-mini")
        XCTAssertEqual(options.summaryEngine, "auto")
    }
}

/// The real on-device model. Opt-in (`ATA_APPLE_MODEL_TESTS=1`), and only on a
/// Mac with Apple Intelligence: CI's runner has the SDK but not the model.
final class AppleModelTests: XCTestCase {
    private let fixture = """
    # Zoom — 22 October 2026 at 14:02

    Duration: 6 min · Participants: Alex, Sam

    ---

    **[00:03] Alex:** Thanks for joining. Today we need to decide when the new version ships.
    **[00:11] Sam:** The build is ready. QA finished on Tuesday and found nothing blocking.
    **[00:20] Alex:** Then let's ship on Friday morning. Sam, can you write the release notes by Thursday?
    **[00:28] Sam:** Yes, I'll have them by Thursday afternoon.
    **[00:34] Alex:** Good. One thing we haven't settled is whether support needs training before the release.
    **[00:41] Sam:** I don't know. We should ask the support lead.
    **[00:47] Alex:** Agreed. I'll book the meeting room for the launch call.

    ---
    _Transcribed locally by Ata (large-v3)._
    """

    private func requireModel() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ATA_APPLE_MODEL_TESTS"] == "1",
                          "set ATA_APPLE_MODEL_TESTS=1 to run Apple's on-device model")
        try XCTSkipUnless(AppleModel.isAvailable, AppleModel.unavailableReason ?? "Apple's model is unavailable")
    }

    func testAppleModelWritesAnOverview() async throws {
        try requireModel()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let summary = await AppleSummarizer.summarize(markdown: fixture, myName: "Alex")
            let text = try XCTUnwrap(summary, "the model wrote nothing")
            XCTAssertTrue(text.hasPrefix("**Overview** — "), text)
            print(text)
        }
        #endif
    }

    /// Small chunks force several partial summaries and the merge pass.
    func testAppleModelMergesChunks() async throws {
        try requireModel()
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let summary = await AppleSummarizer.summarize(markdown: fixture, myName: "Alex", maxCharacters: 250)
            let text = try XCTUnwrap(summary, "the model wrote nothing")
            XCTAssertTrue(text.hasPrefix("**Overview** — "), text)
            XCTAssertEqual(text.components(separatedBy: "**Overview**").count, 2, "one overview, not one per chunk")
            print(text)
        }
        #endif
    }
}
