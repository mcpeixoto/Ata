@testable import Ata
import XCTest

/// Offering a name for a voice, from who was invited.
///
/// Every answer here is a suggestion the user taps or ignores. That is the
/// whole safety property: these tests pin the ranking and the exclusions, but
/// nothing in this path can name a voice on its own.
final class VoiceSuggestionTests: XCTestCase {
    private func attendee(_ name: String, _ email: String? = nil, me: Bool = false) -> MeetingEvent.Attendee {
        MeetingEvent.Attendee(name: name, email: email, isMe: me)
    }

    private func event(_ title: String, _ attendees: [MeetingEvent.Attendee]) -> MeetingEvent {
        MeetingEvent(title: title, startsAt: Date(), attendees: attendees)!
    }

    private func voice(_ name: String?, aliases: [String]? = nil) -> Voice {
        Voice(id: UUID(), name: name, centroid: [1, 0, 0, 0], observations: 1, meetingIDs: [],
              sample: nil, firstSeen: Date(), lastSeen: Date(), isMe: false, number: 1,
              model: VoiceLibrary.model, aliases: aliases)
    }

    func testAVoiceWithNoCalendarHistoryIsNotGuessedAt() {
        XCTAssertEqual(VoiceSuggestions.candidates(for: voice(nil), events: []), [])
    }

    func testThePersonInvitedToEveryMeetingComesFirst() {
        let events = [event("Sync", [attendee("Rita Alves"), attendee("João Dias")]),
                      event("Sync", [attendee("Rita Alves"), attendee("Ana Costa")]),
                      event("Sync", [attendee("Rita Alves"), attendee("Ana Costa")])]
        let out = VoiceSuggestions.candidates(for: voice(nil), events: events)
        XCTAssertEqual(out.first?.name, "Rita Alves")
        XCTAssertEqual(out.first?.shared, 3)
        XCTAssertEqual(out.first?.heardInEvents, 3)
        XCTAssertTrue(out.first!.isUnanimous)
    }

    /// Exactly you and one other person is the strongest evidence there is.
    func testTheOnlyOtherPersonOutranksEveryoneElse() {
        let events = [event("1:1", [attendee("Me", me: true), attendee("Rita Alves")]),
                      event("All hands", [attendee("Ana Costa"), attendee("João Dias"),
                                          attendee("Rita Alves"), attendee("Sam Patel")]),
                      event("All hands", [attendee("Ana Costa"), attendee("João Dias"),
                                          attendee("Rita Alves"), attendee("Sam Patel")])]
        let out = VoiceSuggestions.candidates(for: voice(nil), events: events)
        XCTAssertEqual(out.first?.name, "Rita Alves")
        XCTAssertTrue(out.first!.isOnlyOther)
    }

    func testOnePersonUnderTwoSpellingsIsCountedOnce() {
        let events = [event("Sync", [attendee("Rita", "rita@acme.com")]),
                      event("Sync", [attendee("Rita Alves", "mailto:Rita+cal@acme.com")])]
        let out = VoiceSuggestions.candidates(for: voice(nil), events: events)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.shared, 2)
        XCTAssertEqual(out.first?.name, "Rita Alves", "the fuller name is the one worth showing")
    }

    func testTheSamePersonTwiceOnOneInvitationCountsOnce() {
        let events = [event("Sync", [attendee("Rita Alves", "rita@acme.com"),
                                     attendee("Rita Alves", "rita@acme.com")])]
        XCTAssertEqual(VoiceSuggestions.candidates(for: voice(nil), events: events).first?.shared, 1)
    }

    func testYouAreNeverOfferedAsSomebodyElse() {
        let events = [event("Sync", [attendee("Alex", me: true), attendee("Rita Alves")])]
        XCTAssertEqual(VoiceSuggestions.candidates(for: voice(nil), events: events).map(\.name), ["Rita Alves"])
    }

    /// `isCurrentUser` is not reliable on every account type, so the name the
    /// user already told Ata filters their own row even when the flag is false.
    func testYourOwnNameIsFilteredEvenWhenTheCalendarDidNotSaySo() {
        let events = [event("Sync", [attendee("Alex Peixoto"), attendee("Rita Alves")])]
        let out = VoiceSuggestions.candidates(for: voice(nil), events: events, myName: "Peixoto, Alex")
        XCTAssertEqual(out.map(\.name), ["Rita Alves"])
    }

    func testANameThisVoiceAlreadyHasIsNotASuggestion() {
        let events = [event("Sync", [attendee("Rita Alves"), attendee("Ana Costa")])]
        let out = VoiceSuggestions.candidates(for: voice("Rita Alves"), events: events)
        XCTAssertEqual(out.map(\.name), ["Ana Costa"])
    }

    func testAnAliasCountsAsANameThisVoiceAlreadyHas() {
        let events = [event("Sync", [attendee("Rita Alves"), attendee("Ana Costa")])]
        let out = VoiceSuggestions.candidates(for: voice("Rita", aliases: ["Rita Alves"]), events: events)
        XCTAssertEqual(out.map(\.name), ["Ana Costa"])
    }

    /// Not hidden — the right move is a merge, and the UI says so — but last.
    func testANameAnotherVoiceAlreadyHasRanksLast() {
        let events = [event("Sync", [attendee("Rita Alves"), attendee("Ana Costa")])]
        let out = VoiceSuggestions.candidates(for: voice(nil), events: events,
                                              otherVoices: [voice("Alves, Rita")])
        XCTAssertEqual(out.map(\.name), ["Ana Costa", "Rita Alves"])
        XCTAssertEqual(out.last?.matchesExistingVoice, .reordered)
    }

    func testAnAliasOfAnotherVoiceCountsToo() {
        let events = [event("Sync", [attendee("Rita Alves")])]
        let out = VoiceSuggestions.candidates(for: voice(nil), events: events,
                                              otherVoices: [voice("Rita", aliases: ["Rita Alves"])])
        XCTAssertEqual(out.first?.matchesExistingVoice, .exact)
    }

    func testOnlyAHandfulAreOffered() {
        let crowd = (1...20).map { attendee("Person \($0)") }
        let out = VoiceSuggestions.candidates(for: voice(nil), events: [event("All hands", crowd)])
        XCTAssertEqual(out.count, VoiceSuggestions.maxCandidates)
    }

    func testTheOrderIsTheSameEveryTime() {
        let events = [event("Sync", [attendee("Ana Costa"), attendee("Rita Alves")])]
        let once = VoiceSuggestions.candidates(for: voice(nil), events: events)
        for _ in 0..<20 {
            XCTAssertEqual(VoiceSuggestions.candidates(for: voice(nil), events: events), once)
        }
        XCTAssertEqual(once.map(\.name), ["Ana Costa", "Rita Alves"], "a tie breaks on the name")
    }

    // MARK: Two voices, one person

    func testAVoiceIsOfferedAsSomeoneTheLibraryAlreadyKnows() {
        let rita = voice("Rita Alves")
        let events = [event("Sync", [attendee("Alves, Rita")])]
        XCTAssertEqual(VoiceSuggestions.sameAs(voice(nil), events: events, voices: [rita]).map(\.id), [rita.id])
    }

    func testAVoiceIsNeverTheSamePersonAsItself() {
        let rita = voice("Rita Alves")
        let events = [event("Sync", [attendee("Rita Alves")])]
        XCTAssertTrue(VoiceSuggestions.sameAs(rita, events: events, voices: [rita]).isEmpty)
    }

    func testAnUnnamedVoiceIsNotOfferedAsAnAnswer() {
        let events = [event("Sync", [attendee("Rita Alves")])]
        XCTAssertTrue(VoiceSuggestions.sameAs(voice(nil), events: events, voices: [voice(nil)]).isEmpty)
    }

    /// A first-name match is too weak to propose folding two voices together:
    /// there are two Ritas in every company, and a merge is hard to undo.
    func testAFirstNameAloneIsNotEnoughToCallThemTheSamePerson() {
        let events = [event("Sync", [attendee("Rita Alves")])]
        XCTAssertTrue(VoiceSuggestions.sameAs(voice(nil), events: events, voices: [voice("Rita")]).isEmpty)
    }
}
