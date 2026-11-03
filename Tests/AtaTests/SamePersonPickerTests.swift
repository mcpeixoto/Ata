import XCTest
@testable import Ata

/// Who "Same person as" offers. A wrong name here is a voice deleted.
final class SamePersonPickerTests: XCTestCase {
    private func voice(_ name: String? = nil, number: Int = 1, aliases: [String]? = nil) -> Voice {
        Voice(id: UUID(), name: name, centroid: [1], observations: 1, meetingIDs: ["m"], sample: nil,
              firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0),
              isMe: false, number: number, dismissed: nil, excluded: nil, aliases: aliases)
    }

    private let source = Voice(id: UUID(), name: nil, centroid: [1], observations: 1, meetingIDs: ["m"], sample: nil,
                               firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0),
                               isMe: false, number: 9, dismissed: nil, excluded: nil, aliases: nil)

    private func choices(_ voices: [Voice], likely: [Voice] = [], query: String = "") -> PeopleList.MergeChoices {
        PeopleList.mergeChoices(for: source, voices: voices, likely: likely, query: query)
    }

    func testTheCalendarsGuessesComeFirstAndAreNotRepeated() {
        let ana = voice("Ana"), rita = voice("Rita"), zeca = voice("Zeca")
        let found = choices([zeca, rita, ana], likely: [rita])
        XCTAssertEqual(found.likely.map(\.id), [rita.id])
        XCTAssertEqual(found.others.map(\.id), [ana.id, zeca.id])
    }

    func testAVoiceIsNeverOfferedItselfOrAVoiceWithNoName() {
        let rita = voice("Rita")
        let found = choices([source, voice(number: 2), rita], likely: [source])
        XCTAssertEqual(found.all.map(\.id), [rita.id])
    }

    func testAGuessWithNoNameIsNotOffered() {
        XCTAssertTrue(choices([], likely: [voice(number: 2)]).all.isEmpty)
    }

    func testSearchIgnoresCaseAccentsAndSurroundingSpaces() {
        let joao = voice("João Costa"), rita = voice("Rita")
        XCTAssertEqual(choices([joao, rita], query: "  JOAO ").all.map(\.id), [joao.id])
    }

    func testSearchFindsOtherNamesAPersonGoesBy() {
        let rita = voice("Rita", aliases: ["Margarida"])
        XCTAssertEqual(choices([rita, voice("Ana")], query: "marg").all.map(\.id), [rita.id])
    }

    func testSearchNarrowsTheGuessesToo() {
        let rita = voice("Rita"), ana = voice("Ana")
        let found = choices([rita, ana], likely: [rita, ana], query: "ana")
        XCTAssertEqual(found.likely.map(\.id), [ana.id])
        XCTAssertTrue(found.others.isEmpty)
    }

    func testAPickedNameTheSearchHidIsNotMergeable() {
        let rita = voice("Rita"), ana = voice("Ana")
        XCTAssertNil(choices([rita, ana], query: "ana").picked(rita.id))
        XCTAssertEqual(choices([rita, ana]).picked(rita.id)?.id, rita.id)
        XCTAssertNil(choices([rita, ana]).picked(nil))
    }

    func testOnlyOneIsSetOnlyWhenOneNameIsLeft() {
        let rita = voice("Rita"), ana = voice("Ana")
        XCTAssertNil(choices([rita, ana]).onlyOne)
        XCTAssertEqual(choices([rita, ana], query: "rita").onlyOne?.id, rita.id)
        XCTAssertNil(choices([rita, ana], query: "zzz").onlyOne)
    }
}

final class MainWindowTests: XCTestCase {
    func testOpensAtItsFullHeightOnANormalScreen() {
        XCTAssertEqual(MainWindow.opening(screenHeight: 1000).height, 740)
    }

    func testStaysOnASmallScreen() {
        XCTAssertEqual(MainWindow.opening(screenHeight: 700).height, 652)
    }

    func testNeverOpensBelowItsMinimum() {
        XCTAssertEqual(MainWindow.opening(screenHeight: 300).height, MainWindow.minHeight)
    }

    func testOpensWiderThanItsMinimum() {
        XCTAssertGreaterThanOrEqual(MainWindow.opening(screenHeight: 1000).width, MainWindow.minWidth)
    }
}
