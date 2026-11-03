import Foundation

/// What the People tab lists, and in what order. Pure, so the rules can be tested
/// without a window and each surface draws the same list.
enum PeopleList {
    enum Kind: Equatable { case asking, heardOnce, named, hidden, results }

    struct Section: Equatable {
        var kind: Kind
        var voices: [Voice]
        /// Voices the section holds back, so the list can say they exist.
        var notShown = 0
    }

    /// The one row that is open. Only one at a time: a tall row is fine, a tall list is not.
    enum Row: Hashable {
        case you
        case voice(UUID)
    }

    /// One more than `PeopleModel.heardOnceShown`, so a voice the list holds back
    /// can always be searched for.
    static let searchFrom = 6

    static func showsSearch(voiceCount: Int) -> Bool { voiceCount >= searchFrom }

    /// Tapping the open row closes it; tapping another moves there.
    static func toggled(_ open: Row?, _ tapped: Row) -> Row? { open == tapped ? nil : tapped }

    /// Unnamed voices heard often enough to be worth naming, most frequent first.
    static func asking(_ voices: [Voice]) -> [Voice] {
        voices.filter { $0.name == nil && !$0.isMe && !$0.isDismissed && !$0.isExcluded
            && $0.meetings >= VoiceLibrary.askAfterMeetings }
            .sorted { $0.meetings > $1.meetings }
    }

    /// Unnamed voices heard only once, most recent first.
    static func heardOnce(_ voices: [Voice]) -> [Voice] {
        voices.filter { $0.name == nil && !$0.isMe && !$0.isDismissed && !$0.isExcluded
            && $0.meetings < VoiceLibrary.askAfterMeetings }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    static func named(_ voices: [Voice]) -> [Voice] {
        voices.filter { $0.name != nil && !$0.isMe && !$0.isExcluded }.sorted { $0.meetings > $1.meetings }
    }

    /// Voices that are neither named nor asked about: dismissed, or left out.
    static func hidden(_ voices: [Voice]) -> [Voice] {
        voices.filter { !$0.isMe && ($0.isExcluded || ($0.name == nil && $0.isDismissed)) }
            .sorted { $0.meetings > $1.meetings }
    }

    /// The tab's sections, empty ones left out. A search looks through every voice
    /// but you, hidden ones and the ones the list holds back included.
    static func sections(voices: [Voice], query: String, heardOnceShown: Int) -> [Section] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty {
            let found = voices.filter { !$0.isMe && matches($0, wanted) }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            return found.isEmpty ? [] : [Section(kind: .results, voices: found)]
        }
        let once = heardOnce(voices)
        return [
            Section(kind: .asking, voices: asking(voices)),
            Section(kind: .heardOnce, voices: Array(once.prefix(heardOnceShown)),
                    notShown: max(0, once.count - heardOnceShown)),
            Section(kind: .named, voices: named(voices)),
            Section(kind: .hidden, voices: hidden(voices)),
        ].filter { !$0.voices.isEmpty }
    }

    /// Who a voice can be folded into: the people the calendar suggests, then
    /// everyone else by name.
    static func mergeTargets(for voice: Voice, voices: [Voice], likely: [Voice]) -> [Voice] {
        mergeChoices(for: voice, voices: voices, likely: likely, query: "").all
    }

    /// The names "Same person as" offers. Merging deletes a voice, so the picker
    /// only ever merges a name that is on screen and picked.
    struct MergeChoices: Equatable {
        var likely: [Voice]
        var others: [Voice]

        var all: [Voice] { likely + others }

        /// The picked voice, while the search still shows it.
        func picked(_ id: UUID?) -> Voice? { all.first { $0.id == id } }

        /// The name left when a search narrows down to one.
        var onlyOne: Voice? { all.count == 1 ? all.first : nil }
    }

    static func mergeChoices(for voice: Voice, voices: [Voice], likely: [Voice], query: String) -> MergeChoices {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        let found = voices.filter { $0.id != voice.id && $0.name != nil && (wanted.isEmpty || matches($0, wanted)) }
        let likelyIDs = Set(likely.map(\.id))
        let byName: (Voice, Voice) -> Bool = {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return MergeChoices(likely: found.filter { likelyIDs.contains($0.id) }.sorted(by: byName),
                            others: found.filter { !likelyIDs.contains($0.id) }.sorted(by: byName))
    }

    private static func matches(_ voice: Voice, _ query: String) -> Bool {
        ([voice.displayName] + (voice.aliases ?? [])).contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
