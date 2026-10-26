import Foundation

/// Who a voice might be, from the calendar events of the meetings it was heard in.
///
/// Suggestions, with the reason attached. Nothing in this file writes a name,
/// touches disk, or knows `VoiceLibrary` exists: it is pure, so it can be tested
/// exhaustively, and so a wrong answer can never act on its own. Every answer
/// here is offered to the user and named only if they tap it.
enum VoiceSuggestions {
    /// One answer "Who's this?" can offer, and why.
    struct Candidate: Equatable, Identifiable {
        /// The name as the calendar had it — what the voice is named if tapped.
        let name: String
        let email: String?
        /// Meetings where this voice was heard *and* this person was invited.
        let shared: Int
        /// Meetings where this voice was heard that had a calendar event at all.
        let heardInEvents: Int
        /// The fewest other people on any shared invitation. 1 means a meeting
        /// with exactly you and them, which is as near certain as a suggestion
        /// gets without the user saying so.
        let smallestEvent: Int
        /// A voice already in the library answers to this name. The user
        /// probably wants "Same person as", not a second copy of them, so these
        /// rank last and the UI says why.
        let matchesExistingVoice: Names.Match

        var id: String { email ?? name }

        /// Invited to every meeting this voice was heard in.
        var isUnanimous: Bool { heardInEvents > 0 && shared == heardInEvents }
        /// The only other person on an invitation it was heard in.
        var isOnlyOther: Bool { smallestEvent == 1 }
    }

    /// At most this many. Past three or four the user is reading, not choosing.
    static let maxCandidates = 5

    /// `events` is the calendar event of each meeting `voice` was heard in.
    /// Meetings without one are simply absent, so a library with no calendar
    /// history gives an empty answer rather than a bad one.
    static func candidates(for voice: Voice, events: [MeetingEvent],
                           otherVoices: [Voice] = [], myName: String? = nil) -> [Candidate] {
        guard !events.isEmpty else { return [] }

        /// Everyone already spoken for, so a name in use is not offered twice.
        let mine = voice.allNames
        var shared: [String: Int] = [:]
        var smallest: [String: Int] = [:]
        var display: [String: (name: String, email: String?)] = [:]

        for event in events {
            let others = event.others
            // One person counted once per event, however many rows they have on it.
            var counted = Set<String>()
            for attendee in others {
                // Belt and braces for `isCurrentUser`, which is not reliable on
                // every account type: if EventKit would not say which row is the
                // user, the name they already told Ata still filters it.
                if let myName, Names.compare(attendee.name, myName) >= .reordered { continue }
                let key = attendee.email.flatMap(Names.normalise(email:)) ?? Names.normalise(attendee.name)
                guard !key.isEmpty, counted.insert(key).inserted else { continue }
                shared[key, default: 0] += 1
                smallest[key] = min(smallest[key] ?? .max, max(1, others.count))
                // An invitation with the full name beats one with just "Rita".
                if display[key] == nil || (display[key]?.name.count ?? 0) < attendee.name.count {
                    display[key] = (attendee.name, attendee.email ?? display[key]?.email)
                }
            }
        }

        let candidates = shared.compactMap { key, count -> Candidate? in
            guard let shown = display[key] else { return nil }
            // A name this voice already answers to is not a suggestion.
            if mine.contains(where: { Names.compare($0, shown.name) == .exact }) { return nil }
            let existing = otherVoices.flatMap(\.allNames)
                .map { Names.compare($0, shown.name) }.max() ?? Names.Match.none
            return Candidate(name: shown.name, email: shown.email, shared: count,
                             heardInEvents: events.count, smallestEvent: smallest[key] ?? .max,
                             matchesExistingVoice: existing)
        }

        return Array(candidates.sorted(by: isBetter).prefix(maxCandidates))
    }

    /// Strictly deterministic, so the order can be pinned by a test: a name no
    /// other voice has, then the only-other-person case, then invited to all of
    /// them, then how often, then how small the meeting was, then the name.
    private static func isBetter(_ a: Candidate, _ b: Candidate) -> Bool {
        if (a.matchesExistingVoice == .none) != (b.matchesExistingVoice == .none) {
            return a.matchesExistingVoice == .none
        }
        if a.isOnlyOther != b.isOnlyOther { return a.isOnlyOther }
        if a.isUnanimous != b.isUnanimous { return a.isUnanimous }
        if a.shared != b.shared { return a.shared > b.shared }
        if a.smallestEvent != b.smallestEvent { return a.smallestEvent < b.smallestEvent }
        return Names.normalise(a.name) < Names.normalise(b.name)
    }

    /// Voices this one is probably the same person as: a voice whose own name —
    /// or one of its aliases — is on the invitation of a meeting this voice was
    /// heard in. The diarizer hears one person as two often enough that this is
    /// the commonest correction there is, and the calendar knows the answer.
    static func sameAs(_ voice: Voice, events: [MeetingEvent], voices: [Voice]) -> [Voice] {
        guard !events.isEmpty else { return [] }
        let invited = events.flatMap(\.others)
        guard !invited.isEmpty else { return [] }
        return voices.filter { other in
            guard other.id != voice.id, other.name != nil else { return false }
            return invited.contains { attendee in
                other.allNames.contains { Names.compare($0, attendee.name) >= .reordered }
            }
        }
    }
}
