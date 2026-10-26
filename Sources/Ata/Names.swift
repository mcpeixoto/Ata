import Foundation

/// Comparing written names, which is the whole difficulty: a calendar
/// invitation says "Alves, Rita (Acme)", the user typed "Rita", and they are one
/// person.
///
/// Everything here only ever ranks a suggestion or explains it. Nothing in Ata
/// names a voice from these answers on its own — a name the user did not check
/// is the one thing this must never produce.
enum Names {
    /// How sure two written names are the same person.
    enum Match: Int, Comparable, Sendable {
        case none = 0
        /// One is the other's first word, at a word boundary: "Rita" and
        /// "Rita Alves". The commonest real case — a voice named by hand from
        /// what someone is called out loud, against an invitation with their
        /// full name — and the weakest, because there are two Ritas everywhere.
        case firstName = 1
        /// The same words in another order: "Alves, Rita" and "Rita Alves".
        case reordered = 2
        /// Equal once case, accents, punctuation and spacing are folded away.
        case exact = 3

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    static func compare(_ a: String, _ b: String) -> Match {
        let x = normalise(a), y = normalise(b)
        guard !x.isEmpty, !y.isEmpty else { return .none }
        if x == y { return .exact }
        if sortedWords(a) == sortedWords(b) { return .reordered }
        let xs = x.split(separator: " "), ys = y.split(separator: " ")
        if let first = xs.first, let other = ys.first, first == other, xs.count != ys.count {
            return .firstName
        }
        return .none
    }

    /// A name as a key: a bracketed or piped tail dropped ("Rita Alves (Acme)",
    /// "Rita Alves | Engineering"), then case, accents and width folded, every
    /// run of non-alphanumerics turned into one space, trimmed.
    ///
    /// Accents go because an invitation and a typed name disagree about them far
    /// more often than two people differ by one — "João" and "Joao" are the same
    /// person about as reliably as anything here gets.
    static func normalise(_ name: String) -> String {
        var text = name
        for separator in ["(", "|", "<"] {
            if let cut = text.range(of: separator) { text = String(text[..<cut.lowerBound]) }
        }
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// `normalise` with the words sorted, so "Alves, Rita" and "Rita Alves"
    /// agree. Weaker, and only reached when `normalise` does not match.
    static func sortedWords(_ name: String) -> String {
        normalise(name).split(separator: " ").sorted().joined(separator: " ")
    }

    /// An address as a key: `mailto:` dropped, lowercased, and a `+tag` before
    /// the @ dropped, so "rita+cal@acme.com" and "rita@acme.com" are one person.
    /// Nil when there is no @ in it.
    static func normalise(email: String) -> String? {
        var text = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("mailto:") { text.removeFirst("mailto:".count) }
        let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let local = parts[0].split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !local.isEmpty else { return nil }
        return "\(local)@\(parts[1])"
    }

    /// The part of an address a person would recognise, for an invitation that
    /// carried no name at all: "rita.alves@acme.com" → "rita.alves".
    static func nameFromEmail(_ email: String) -> String? {
        guard let normalised = normalise(email: email) else { return nil }
        let local = normalised.split(separator: "@")[0]
        return local.isEmpty ? nil : String(local)
    }
}
