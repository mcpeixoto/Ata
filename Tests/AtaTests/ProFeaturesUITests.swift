@testable import Ata
import XCTest

/// Paywall wiring, the template list and the Ask citation chips. No model call,
/// and nothing here touches the meetings folder.
@MainActor
final class ProFeaturesUITests: XCTestCase {
    private let suite = "ai.interactive.ata.tests.profeaturesui"

    override func tearDown() {
        ProGate.presentPaywall = { _ in }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testALockedTapPresentsThatFeature() {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        var presented: [ProFeature] = []
        ProGate.presentPaywall = { presented.append($0) }

        XCTAssertFalse(ProGate.lockedTap(.askMeetings, isPro: false, defaults: defaults))
        XCTAssertFalse(ProGate.lockedTap(.customTemplates, isPro: false, defaults: defaults))
        XCTAssertEqual(presented, [.askMeetings, .customTemplates])

        presented.removeAll()
        XCTAssertTrue(ProGate.lockedTap(.askMeetings, isPro: true, defaults: defaults))
        XCTAssertTrue(presented.isEmpty)
    }

    func testTheExampleTemplateIsReadOnlyAndShownToFreeUsers() {
        let saved = [CustomTemplate(name: "Board", instructions: "Decisions only.", sections: ["Decisions"])]
        let rows = TemplateListModel.rows(saved: saved, isPro: false)

        XCTAssertEqual(rows.map(\.isExample), [true, false])
        XCTAssertFalse(rows[0].canEdit)
        XCTAssertFalse(rows[1].canEdit)
        XCTAssertEqual(rows[0].template.name, "Example: Client call")
        XCTAssertEqual(rows[0].template.sections.count, 3)
        XCTAssertFalse(rows[0].template.instructions.isEmpty)

        let pro = TemplateListModel.rows(saved: saved, isPro: true)
        XCTAssertFalse(pro[0].canEdit, "the example stays read-only for Pro")
        XCTAssertTrue(pro[1].canEdit)
    }

    func testFreeUsersGetTheUnlockCardAndALockedAddButton() {
        XCTAssertTrue(TemplateListModel.showsUnlockCard(isPro: false))
        XCTAssertFalse(TemplateListModel.showsUnlockCard(isPro: true))
        XCTAssertEqual(TemplateListModel.addSymbol(isPro: false), "lock.fill")
        XCTAssertEqual(TemplateListModel.addSymbol(isPro: true), "plus")
        XCTAssertFalse(TemplateListModel.showsEmptyLine(saved: [], isPro: false))
    }

    func testAProUserWithNoTemplatesSeesTheEmptyLine() {
        XCTAssertTrue(TemplateListModel.showsEmptyLine(saved: [], isPro: true))
        XCTAssertTrue(TemplateListModel.showsEmptyLine(saved: [TemplateExample.template], isPro: true),
                      "the sample does not count as one of theirs")
        let own = CustomTemplate(name: "Board", instructions: "Decisions only.", sections: ["Decisions"])
        XCTAssertFalse(TemplateListModel.showsEmptyLine(saved: [own], isPro: true))
        XCTAssertFalse(TemplateListModel.showsEmptyLine(saved: [own], isPro: false))
    }

    func testTheInstructionsCounterCapsAtOneThousand() {
        let over = String(repeating: "a", count: 1_001)
        XCTAssertEqual(TemplateDraft.instructions(over).count, CustomTemplate.instructionLimit)
        XCTAssertEqual(TemplateDraft.instructions(over).count, 1_000)
        XCTAssertEqual(TemplateDraft.instructions(String(repeating: "b", count: 1_000)).count, 1_000)
        XCTAssertEqual(TemplateDraft.instructions("short"), "short")
    }

    func testCitationChipsMapToTheMeetingAndTheTime() {
        let meetings = [
            AskSource(id: "pricing", title: "Pricing", transcript: ""),
            AskSource(id: "kickoff", title: "Kickoff", transcript: ""),
        ]
        let answer = "We settled the price [Pricing · 12:04] and left the logo [Kickoff · 1:02:03]."
        let chips = AskChips.chips(in: answer, meetings: meetings)

        XCTAssertEqual(chips.map(\.meetingID), ["pricing", "kickoff"])
        XCTAssertEqual(chips.map(\.milliseconds), [
            (12 * 60 + 4) * 1_000,
            (1 * 3_600 + 2 * 60 + 3) * 1_000,
        ])
        XCTAssertEqual(chips.map(\.title), ["Pricing", "Kickoff"])
    }

    func testTheRequestedFeatureLeadsThePaywallLines() {
        XCTAssertEqual(ProFeature.lines(highlighted: nil), Array(ProFeature.allCases))
        XCTAssertEqual(ProFeature.lines(highlighted: .customTemplates).first, .customTemplates)
        XCTAssertEqual(ProFeature.lines(highlighted: .documentExport),
                       [.documentExport, .askMeetings, .customTemplates])
        XCTAssertEqual(Set(ProFeature.lines(highlighted: .askMeetings)), Set(ProFeature.allCases))
    }
}
