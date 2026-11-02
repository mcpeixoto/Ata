import XCTest
@testable import Ata

/// What the People tab lists, and in what order. Pure: no disk, no SwiftUI.
final class PeopleListTests: XCTestCase {
    private func voice(_ name: String? = nil, number: Int = 1, meetings: Int = 1, aliases: [String]? = nil,
                       isMe: Bool = false, dismissed: Bool? = nil, excluded: Bool? = nil) -> Voice {
        Voice(id: UUID(), name: name, centroid: [1], observations: 1,
              meetingIDs: (0..<meetings).map { "m\($0)" }, sample: nil,
              firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0),
              isMe: isMe, number: number, dismissed: dismissed, excluded: excluded, aliases: aliases)
    }

    private func list(_ voices: [Voice], query: String = "", heardOnceShown: Int = 5) -> [PeopleList.Section] {
        PeopleList.sections(voices: voices, query: query, heardOnceShown: heardOnceShown)
    }

    func testVoicesToNameComeFirstThenPeopleThenHidden() {
        let rita = voice("Rita", meetings: 3)
        let often = voice(number: 2, meetings: 4)
        let once = voice(number: 3, meetings: 1)
        let tv = voice(number: 4, meetings: 2, excluded: true)
        let sections = list([rita, tv, once, often])

        XCTAssertEqual(sections.map(\.kind), [.asking, .heardOnce, .named, .hidden])
        XCTAssertEqual(sections.map { $0.voices.map(\.id) },
                       [[often.id], [once.id], [rita.id], [tv.id]])
    }

    func testYourOwnVoiceIsNeverInTheList() {
        let me = voice("Miguel", meetings: 9, isMe: true)
        XCTAssertTrue(list([me]).isEmpty)
        XCTAssertTrue(list([me], query: "Miguel").isEmpty)
    }

    func testEmptySectionsAreLeftOut() {
        XCTAssertEqual(list([voice("Rita")]).map(\.kind), [.named])
    }

    func testVoicesToNameGoMostHeardFirst() {
        let two = voice(number: 1, meetings: 2)
        let five = voice(number: 2, meetings: 5)
        XCTAssertEqual(list([two, five]).first?.voices.map(\.id), [five.id, two.id])
    }

    func testOneOffVoicesAreCappedAndTheRestAreCounted() throws {
        let many = (1...8).map { voice(number: $0) }
        let section = try XCTUnwrap(list(many, heardOnceShown: 5).first)
        XCTAssertEqual(section.kind, .heardOnce)
        XCTAssertEqual(section.voices.count, 5)
        XCTAssertEqual(section.notShown, 3)
    }

    func testSearchFindsAVoiceTheCapHid() {
        var many = (1...8).map { voice(number: $0) }
        let hidden = voice(number: 42)
        many.append(hidden)
        let sections = list(many, query: L("Voice %d", 42), heardOnceShown: 5)
        XCTAssertEqual(sections.map(\.kind), [.results])
        XCTAssertEqual(sections.first?.voices.map(\.id), [hidden.id])
    }

    func testSearchIgnoresCaseAndAccents() {
        let joao = voice("João")
        XCTAssertEqual(list([joao, voice("Rita")], query: "JOAO").first?.voices.map(\.id), [joao.id])
    }

    func testSearchMatchesOtherNamesAPersonGoesBy() {
        let rita = voice("Rita", aliases: ["Rita Alves"])
        XCTAssertEqual(list([rita], query: "alves").first?.voices.map(\.id), [rita.id])
    }

    func testSearchReachesHiddenVoices() {
        let tv = voice("Television", excluded: true)
        XCTAssertEqual(list([tv], query: "tele").first?.voices.map(\.id), [tv.id])
    }

    func testSearchOfOnlySpacesIsNotASearch() {
        XCTAssertEqual(list([voice("Rita")], query: "   ").map(\.kind), [.named])
    }

    func testASearchWithNoMatchHasNoSections() {
        XCTAssertTrue(list([voice("Rita")], query: "zzz").isEmpty)
    }

    func testSearchBoxOnlyAppearsOnceTheListIsLong() {
        XCTAssertFalse(PeopleList.showsSearch(voiceCount: PeopleList.searchFrom - 1))
        XCTAssertTrue(PeopleList.showsSearch(voiceCount: PeopleList.searchFrom))
    }

    func testOneRowIsOpenAtATime() {
        let a = PeopleList.Row.voice(UUID()), b = PeopleList.Row.voice(UUID())
        XCTAssertEqual(PeopleList.toggled(nil, a), a)
        XCTAssertEqual(PeopleList.toggled(a, b), b, "opening a row closes the other")
        XCTAssertNil(PeopleList.toggled(b, b), "tapping the open row closes it")
    }

    func testSamePersonOffersTheLikelyOnesFirst() {
        let source = voice(number: 1)
        let ana = voice("Ana"), rita = voice("Rita"), zeca = voice("Zeca"), unnamed = voice(number: 2)
        let offered = PeopleList.mergeTargets(for: source, voices: [zeca, unnamed, source, rita, ana],
                                              likely: [rita])
        XCTAssertEqual(offered.map(\.id), [rita.id, ana.id, zeca.id])
    }
}

/// Naming from the People tab must not hold up the UI for a voice heard in many
/// meetings, and every transcript still has to end up right.
@MainActor
final class PeopleRedrawTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()
    }

    /// Every voice its own direction, so none is matched to one an earlier test left.
    private static var nextDimension = 0

    /// A finished meeting with one speaker, and the voice it points at.
    private func meetingWithVoice() throws -> (Meeting, Voice) {
        var m = try Meeting.new(app: "Zoom")
        m.duration = 60
        m.status = .done
        Library.save(m)
        let stored = StoredTranscript(segments: [.init(start: 0, end: 1_000, text: "Morning everyone", speaker: "S1")],
                                      coarse: false, summary: nil, engine: "local", model: "m")
        try stored.save(to: m.storedTranscriptURL)
        var embedding = [Float](repeating: 0, count: 64)
        embedding[Self.nextDimension] = 1
        Self.nextDimension += 1
        let library = VoiceLibrary()
        let assigned = library.assign([MeetingSpeaker(label: "S1", embedding: embedding, seconds: 30, voiceID: nil)],
                                      meetingID: m.id)
        try library.save()
        try MeetingVoices(speakers: assigned, turns: []).save(for: m)
        let model = PeopleModel.shared
        model.reload()
        return (m, try XCTUnwrap(model.voices.first { $0.id == assigned[0].voiceID }))
    }

    func testRenamingLaterUpdatesTheListAtOnceAndTheTranscriptSoonAfter() async throws {
        let (m, voice) = try meetingWithVoice()
        let model = PeopleModel.shared
        model.rename(voice, to: "Rita", redraw: .background)
        XCTAssertEqual(model.voices.first { $0.id == voice.id }?.name, "Rita", "the list does not wait")

        await model.finishRedraws()
        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Rita:**"), md)
    }

    func testRenamingWithoutSayingSoStillRewritesBeforeReturning() throws {
        let (m, voice) = try meetingWithVoice()
        PeopleModel.shared.rename(voice, to: "Samuel")
        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Samuel:**"), "a meeting's own window reads it straight after: \(md)")
    }

    func testMergingLaterPointsTheMeetingAtTheVoiceKept() async throws {
        let (m, source) = try meetingWithVoice()
        let (_, kept) = try meetingWithVoice()
        let model = PeopleModel.shared
        model.rename(kept, to: "Teresa", redraw: .background)
        let target = try XCTUnwrap(model.voices.first { $0.id == kept.id })
        model.merge(source, into: target, redraw: .background)
        XCTAssertNil(model.voices.first { $0.id == source.id }, "the list does not wait")

        await model.finishRedraws()
        XCTAssertEqual(MeetingVoices.load(for: m)?.speakers.first?.voiceID, kept.id)
        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Teresa:**"), md)
    }

    func testForgettingLaterLeavesNoMeetingPointingAtTheVoice() async throws {
        let (m, voice) = try meetingWithVoice()
        let model = PeopleModel.shared
        model.forget(voice, redraw: .background)
        XCTAssertNil(model.voices.first { $0.id == voice.id })

        await model.finishRedraws()
        XCTAssertNil(MeetingVoices.load(for: m)?.speakers.first?.voiceID)
    }

    func testRedrawsRunInTheOrderTheyWereAsked() async throws {
        let (m, voice) = try meetingWithVoice()
        let model = PeopleModel.shared
        model.rename(voice, to: "First", redraw: .background)
        let renamed = try XCTUnwrap(model.voices.first { $0.id == voice.id })
        model.rename(renamed, to: "Second", redraw: .background)

        await model.finishRedraws()
        let md = try String(contentsOf: m.transcriptURL, encoding: .utf8)
        XCTAssertTrue(md.contains("Second:**"), md)
    }
}
