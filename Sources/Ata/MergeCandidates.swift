import CoreGraphics
import Foundation

/// Who "Merge with…" offers, and in what order.
///
/// Pure on purpose: the People tab and a meeting's People tab both draw this,
/// and a wrong name here is a voice deleted. Nothing in this file writes.
enum MergeCandidates {
    struct Result: Equatable {
        var suggested: [Voice]
        var others: [Voice]

        var isEmpty: Bool { suggested.isEmpty && others.isEmpty }
        var count: Int { suggested.count + others.count }

        func contains(_ id: UUID) -> Bool {
            suggested.contains { $0.id == id } || others.contains { $0.id == id }
        }
    }

    /// Named voices other than `source`. `suggested` (the calendar's guess)
    /// comes first and is not repeated below. Everyone else is alphabetical,
    /// so a long library can be scanned and searched rather than scrolled as
    /// one undifferentiated menu.
    static func arrange(source: Voice, voices: [Voice], suggested: [Voice], query: String) -> Result {
        let named = voices.filter { $0.id != source.id && hasName($0) }
        let namedIDs = Set(named.map(\.id))
        let suggestedKept = suggested.filter { namedIDs.contains($0.id) && matches($0, query: query) }
        let suggestedIDs = Set(suggestedKept.map(\.id))
        let others = named
            .filter { !suggestedIDs.contains($0.id) && matches($0, query: query) }
            .sorted(by: byName)
        return Result(suggested: suggestedKept, others: others)
    }

    /// A blank query matches everyone. Otherwise the name, any alias, and the
    /// "Voice 6" label are folded the same way invitations are, so "joao"
    /// finds "João".
    static func matches(_ voice: Voice, query: String) -> Bool {
        let q = Names.normalise(query)
        guard !q.isEmpty else { return true }
        if Names.normalise(voice.displayName).contains(q) { return true }
        return voice.allNames.contains { Names.normalise($0).contains(q) }
    }

    private static func hasName(_ voice: Voice) -> Bool {
        guard let name = voice.name else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func byName(_ a: Voice, _ b: Voice) -> Bool {
        let an = Names.normalise(a.name ?? "")
        let bn = Names.normalise(b.name ?? "")
        if an != bn { return an < bn }
        return a.id.uuidString < b.id.uuidString
    }
}

/// How tall the scrolling part of the People tab may grow in the menu bar.
///
/// The panel sizes itself to its SwiftUI view. An uncapped list of voices
/// pushes the tab bar, Forget and Quit off the screen, which is the panel
/// no longer being usable. `reserve` is the chrome that stays put (header,
/// tabs, the You row, footer); the list gets what remains, and stops growing
/// once it is tall enough to scan.
enum PeoplePaneLayout {
    /// Past this many open rows the menu list scrolls. Fewer stay at their
    /// own height, so a short library does not sit in an empty well.
    static let uncappedRows = 6

    /// Tall enough to read several people; taller just makes the panel a
    /// full-screen column of rows.
    static let listCapCeiling: CGFloat = 460

    /// Below this the list is a sliver. A very small screen may still clip
    /// slightly rather than hide the rows entirely.
    static let listCapMinimum: CGFloat = 120

    /// Popover chrome plus the pinned You block and the learned-voices line.
    static let menuReserve: CGFloat = 560

    /// The merge picker replaces that You block with a shorter header, so it
    /// may use more of the screen for the names.
    static let mergeReserve: CGFloat = 420

    static func listCap(screenHeight: CGFloat, reserve: CGFloat) -> CGFloat {
        min(listCapCeiling, max(listCapMinimum, screenHeight - reserve))
    }
}
