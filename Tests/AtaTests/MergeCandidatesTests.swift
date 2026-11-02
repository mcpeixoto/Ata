@testable import Ata
import XCTest

/// Who the merge picker lists. A tap here deletes a voice, so the order and
/// the filter are pinned: the calendar's guess first, everyone else by name,
/// and a typed query that cannot quietly include the voice being merged.
final class MergeCandidatesTests: XCTestCase {
    private func voice(_ name: String?, id: UUID = UUID(), aliases: [String]? = nil,
                       meetings: Int = 1, me: Bool = false, number: Int? = 1) -> Voice {
        Voice(id: id, name: name, centroid: [1, 0, 0, 0], observations: 1,
              meetingIDs: (0..<meetings).map { "m\($0)" },
              sample: nil, firstSeen: Date(), lastSeen: Date(), isMe: me, number: number,
              model: nil, aliases: aliases)
    }

    func testOnlyNamedVoicesAreOfferedAndTheSourceIsLeftOut() {
        let source = voice(nil, number: 6)
        let rita = voice("Rita")
        let unnamed = voice(nil, number: 2)
        let blank = voice("   ")
        let result = MergeCandidates.arrange(source: source,
                                              voices: [source, rita, unnamed, blank],
                                              suggested: [], query: "")
        XCTAssertEqual(result.others.map(\.id), [rita.id])
        XCTAssertTrue(result.suggested.isEmpty)
    }

    func testSuggestionsComeFirstAndAreNotListedTwice() {
        let source = voice(nil, number: 4)
        let sam = voice("Sam")
        let ana = voice("Ana")
        let rita = voice("Rita")
        let result = MergeCandidates.arrange(source: source,
                                              voices: [source, rita, ana, sam],
                                              suggested: [sam, ana], query: "")
        XCTAssertEqual(result.suggested.map(\.name), ["Sam", "Ana"])
        XCTAssertEqual(result.others.map(\.name), ["Rita"])
    }

    func testASuggestionThatIsNotARealTargetIsDropped() {
        let source = voice("Voice extra")
        let stranger = voice("Stranger")
        let result = MergeCandidates.arrange(source: source, voices: [source],
                                              suggested: [stranger, source], query: "")
        XCTAssertTrue(result.isEmpty)
    }

    func testTheRestAreAlphabeticalWithAccentsFolded() {
        let source = voice(nil)
        let joao = voice("João")
        let ana = voice("Álvaro")
        let result = MergeCandidates.arrange(source: source, voices: [joao, ana, source],
                                              suggested: [], query: "")
        XCTAssertEqual(result.others.map(\.name), ["Álvaro", "João"])
    }

    func testAQueryMatchesANameAnAliasAndIgnoresCaseAndAccents() {
        let source = voice(nil, number: 3)
        let rita = voice("Rita", aliases: ["Rita Alves"])
        let joao = voice("João Costa")
        let voices = [source, rita, joao]
        XCTAssertEqual(MergeCandidates.arrange(source: source, voices: voices,
                                                suggested: [], query: "alv").others.map(\.name), ["Rita"])
        XCTAssertEqual(MergeCandidates.arrange(source: source, voices: voices,
                                                suggested: [], query: "JOAO").others.map(\.name), ["João Costa"])
        XCTAssertTrue(MergeCandidates.arrange(source: source, voices: voices,
                                               suggested: [rita], query: "zzz").isEmpty)
    }

    func testABlankQueryMatchesEveryoneAndAnUnnamedLabelStillSearches() {
        let source = voice("Rita")
        var unnamed = voice(nil, number: 6)
        unnamed.number = 6
        XCTAssertTrue(MergeCandidates.matches(unnamed, query: "   "))
        XCTAssertTrue(MergeCandidates.matches(unnamed, query: "6"))
        XCTAssertFalse(MergeCandidates.matches(unnamed, query: "7"))
        XCTAssertTrue(MergeCandidates.matches(source, query: ""))
    }

    func testTheVoiceBeingMergedIsNeverListedEvenWhenTheQueryMatches() {
        let rita = voice("Rita")
        let other = voice("Rita Alves")
        let result = MergeCandidates.arrange(source: rita, voices: [rita, other],
                                              suggested: [rita], query: "rita")
        XCTAssertEqual(result.others.map(\.id), [other.id])
        XCTAssertTrue(result.suggested.isEmpty)
    }

    func testYourOwnNamedVoiceIsATarget() {
        let source = voice(nil, number: 2)
        let me = voice("Alex", me: true)
        let result = MergeCandidates.arrange(source: source, voices: [source, me],
                                              suggested: [], query: "alex")
        XCTAssertEqual(result.others.map(\.id), [me.id])
        XCTAssertTrue(result.others[0].isMe)
    }

    /// The menu bar panel is as tall as its SwiftUI view. This is the cap that
    /// keeps the tab bar and Quit on screen once the voice list is long.
    func testTheListCapFitsTheScreenAndStopsGrowing() {
        XCTAssertEqual(PeoplePaneLayout.listCap(screenHeight: 900, reserve: PeoplePaneLayout.menuReserve), 340)
        XCTAssertEqual(PeoplePaneLayout.listCap(screenHeight: 2_000, reserve: PeoplePaneLayout.menuReserve),
                       PeoplePaneLayout.listCapCeiling)
        XCTAssertEqual(PeoplePaneLayout.listCap(screenHeight: 600, reserve: PeoplePaneLayout.menuReserve),
                       PeoplePaneLayout.listCapMinimum)
        XCTAssertLessThan(PeoplePaneLayout.mergeReserve, PeoplePaneLayout.menuReserve)
    }
}
