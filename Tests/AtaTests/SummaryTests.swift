@testable import Ata
import XCTest

final class VocabularyTests: XCTestCase {
    func testTypedWordsAndNamesMergeWithoutDuplicates() {
        let terms = Vocabulary.terms(userText: "Copilot, Attio\nBernardo Reis; copilot",
                                     names: ["Bernardo Reis", "Rita Alves"])
        XCTAssertEqual(terms, ["Copilot", "Attio", "Bernardo Reis", "Rita Alves"])
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(Vocabulary.terms(userText: " , \n", names: []), [])
        XCTAssertNil(Vocabulary.spellingInstruction([]))
    }

    /// The field report that prompted this: "Copilot" transcribed as "copado".
    func testThePromptIsAListTheModelCanSpellFrom() {
        XCTAssertTrue(Vocabulary.spellingInstruction(["Copilot"])!.contains("Copilot"))
    }
}

final class SummaryTemplateTests: XCTestCase {
    func testATemplateSteersTheWriter() {
        XCTAssertTrue(SummaryTemplate.standard.focus.isEmpty)
        XCTAssertTrue(SummaryTemplate.sales.focus.contains("sales call"))
    }

    func testAnUnknownTemplateIsStandard() {
        XCTAssertEqual(SummaryTemplate.named("nonsense"), .standard)
        XCTAssertEqual(SummaryTemplate.named(nil), .standard)
        XCTAssertEqual(SummaryTemplate.named("one-to-one"), .oneToOne)
    }
}

final class FollowUpTests: XCTestCase {
    private let summary = """
    **Overview** — Agreed to ship the beta on the 3rd and move billing to the next sprint.

    **Decisions**
    - Ship on the 3rd

    **Action items**
    - Alex: send the beta invite list by Thursday
    - Rita: confirm the support rota

    **Open questions**
    - Who tells support?
    """

    func testADraftIsSubjectOverviewAndNextSteps() {
        let draft = FollowUp.draft(summary: summary, meetingTitle: "Weekly sync", myName: "Miguel")
        XCTAssertTrue(draft.hasPrefix("Subject: Follow-up: Weekly sync"), draft)
        XCTAssertTrue(draft.contains("Agreed to ship the beta on the 3rd"), draft)
        XCTAssertTrue(draft.contains("- Alex: send the beta invite list by Thursday"), draft)
        XCTAssertTrue(draft.contains("- Rita: confirm the support rota"), draft)
        XCTAssertFalse(draft.contains("Who tells support?"), "open questions are not next steps")
        XCTAssertTrue(draft.hasSuffix("Miguel"), draft)
    }

    func testNoActionItemsMeansNoNextStepsSection() {
        let draft = FollowUp.draft(summary: "**Overview** — A quick catch-up.", meetingTitle: "Call", myName: "Miguel")
        XCTAssertFalse(draft.contains("Next steps"), draft)
        XCTAssertTrue(draft.contains("A quick catch-up."), draft)
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
