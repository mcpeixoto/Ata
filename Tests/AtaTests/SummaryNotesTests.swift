@testable import Ata
import XCTest

/// What a summary keeps of the model's replies. Pure: no model.
final class SummaryNotesTests: XCTestCase {
    private let transcript = """
    # Zoom — 22 October 2026 at 14:02

    Duration: 6 min · Participants: Alex, Sam

    ## Summary

    **Overview** — An older summary.

    ---

    **[00:03] Alex:** Thanks for joining.

    **[01:02:11] Voice 2:** The build is ready.

    ---
    _Transcribed locally by Ata (large-v3)._
    """

    func testTheModelGetsOnlyTheSpokenLines() {
        XCTAssertEqual(SummaryNotes.conversation(from: transcript),
                       "Alex: Thanks for joining.\n\nVoice 2: The build is ready.")
    }

    func testTextWithoutHeaderOrFooterIsKept() {
        XCTAssertEqual(SummaryNotes.conversation(from: "Just words."), "Just words.")
    }

    func testAReplyIsATopicThenPoints() {
        let part = SummaryNotes.part(fromReply: "**Tema:** Lançamento\n\n* Sai na sexta\n- **Rita** escreve as notas\n• Sem atrasos\n1. Teste feito", of: "")
        XCTAssertEqual(part.topic, "Lançamento")
        XCTAssertEqual(part.points, ["Sai na sexta", "Rita escreve as notas", "Sem atrasos", "Teste feito"])
    }

    func testATopicWithAColonInASentenceIsNotALabel() {
        XCTAssertEqual(SummaryNotes.part(fromReply: "They talked about two things: dates and cost", of: "").topic,
                       "They talked about two things: dates and cost")
    }

    private let spoken = """
    Alex: We looked at the build this morning and the release can go out on Friday if nothing else turns up.

    Sam: Then I will write the release notes tonight and send them to the whole team for a review.
    """

    /// Seen on a real meeting: the model answered with a stretch of the transcript.
    func testAPointThatIsACopyOfTheTranscriptIsDropped() {
        let reply = """
        Release
        - Alex: We looked at the build this morning and the release can go out on Friday
        - Sam will write the release notes tonight
        """
        XCTAssertEqual(SummaryNotes.part(fromReply: reply, of: spoken).points, ["Sam will write the release notes tonight"])
    }

    func testAPointUsingAPhraseFromTheTranscriptIsKept() {
        XCTAssertFalse(SummaryNotes.isPasted("The team agreed the release can go out on Friday, subject to a last check of the build",
                                             from: spoken))
    }

    func testALabelAndAShortQuoteIsDropped() {
        XCTAssertTrue(SummaryNotes.isPasted("Sam: \"Then I will write the release notes.\"", from: spoken))
    }

    func testAPersonAndWhatTheyWillDoIsKept() {
        XCTAssertFalse(SummaryNotes.isPasted("Sam: writes the notes tonight", from: spoken))
    }

    func testAPointFarTooLongToBeOneIsDropped() {
        XCTAssertTrue(SummaryNotes.isPasted(String(repeating: "word ", count: 60), from: spoken))
    }

    func testAnOverviewStopsAfterThreeSentences() {
        XCTAssertEqual(SummaryNotes.overview(fromReply: "**One.** Two.\nThree. Four. Five."), "One. Two. Three.")
    }

    func testAnEmptyOverviewIsEmpty() {
        XCTAssertEqual(SummaryNotes.overview(fromReply: " \n "), "")
    }

    func testAnEmptyReplyHasNothing() {
        XCTAssertEqual(SummaryNotes.part(fromReply: " \n ", of: ""), SummaryNotes.Part(topic: "", points: []))
    }

    /// Seen on a real meeting: one sentence again and again with only a number changing.
    func testALoopOfTheSameSentenceBecomesOnePoint() {
        let loop = [40, 30, 20, 10].map { "Someone should check whether the invoice covers \($0) hours of work" }
        let points = SummaryNotes.keyPoints([.init(topic: "Invoice", points: loop)])
        XCTAssertEqual(points, [loop[0]])
    }

    func testDifferentPointsAreAllKept() {
        let distinct = ["Launch moves to Friday", "Rita updates the screenshots", "Pricing page stays live"]
        XCTAssertEqual(SummaryNotes.keyPoints([.init(topic: "Launch", points: distinct)]), distinct)
    }

    func testTheSamePointInTwoPartsIsKeptOnce() {
        let parts: [SummaryNotes.Part] = [.init(topic: "A", points: ["Launch moves to Friday morning"]),
                                          .init(topic: "B", points: ["Launch moves to Friday morning!"])]
        XCTAssertEqual(SummaryNotes.keyPoints(parts), ["Launch moves to Friday morning"])
    }

    func testTheEndOfALongMeetingIsNotCrowdedOut() {
        let parts = (0..<30).map { i in
            SummaryNotes.Part(topic: "Part \(i)", points: (0..<5).map { "Subject\(i) detail\($0)" })
        }
        let points = SummaryNotes.keyPoints(parts)
        XCTAssertTrue(points.contains("Subject29 detail0"), "\(points.count) points")
        XCTAssertEqual(points.count, 60)
    }

    func testAShortMeetingKeepsEverythingTheModelSaid() {
        let part = SummaryNotes.Part(topic: "A", points: (0..<5).map { "Subject\($0) detail" })
        XCTAssertEqual(SummaryNotes.keyPoints([part]).count, 5)
    }

    func testTheShapeIsOverviewThenKeyPoints() {
        XCTAssertEqual(SummaryNotes.markdown(overview: "A catch-up.", points: ["One", "Two"], skippedPart: false),
                       "**Overview** — A catch-up.\n\n**Key points**\n- One\n- Two")
    }

    func testASkippedPartIsSaid() {
        let text = SummaryNotes.markdown(overview: "A catch-up.", points: ["One"], skippedPart: true)
        XCTAssertTrue(text.hasSuffix("Part of this conversation could not be summarized."), text)
    }

    func testNothingToSayIsEmpty() {
        XCTAssertEqual(SummaryNotes.markdown(overview: "", points: [], skippedPart: true), "")
    }

    /// New summaries have no action items, so a follow-up has no next steps to invent.
    func testAFollowUpFromKeyPointsHasOnlyTheOverview() {
        let summary = SummaryNotes.markdown(overview: "A catch-up.", points: ["One"], skippedPart: false)
        let draft = FollowUp.draft(summary: summary, meetingTitle: "Call", myName: "Alex")
        XCTAssertTrue(draft.contains("A catch-up."), draft)
        XCTAssertFalse(draft.contains("Next steps"), draft)
        XCTAssertFalse(draft.contains("- One"), draft)
    }
}
