import Foundation

/// The words Ata should get right: names and terms a speech model will
/// otherwise spell by ear — "Copilot" coming back as "copado" is the kind
/// that turns up in real transcripts.
///
/// Two sources: what the user typed in Settings (`Pref.dictionary`), and the
/// name of every voice they have ever named in People, which Ata knows
/// already and ought not to need typing again.
enum Vocabulary {
    /// More than this stops helping: the hint is read as context, not gospel,
    /// and a page of it drowns the few words that matter.
    static let maxTerms = 60

    static func terms(userText: String, names: [String]) -> [String] {
        let typed = userText.split { $0 == "," || $0 == "\n" || $0 == ";" }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var seen = Set<String>()
        var out: [String] = []
        for raw in typed + names.map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard !raw.isEmpty, seen.insert(raw.lowercased()).inserted else { continue }
            out.append(raw)
            if out.count == maxTerms { break }
        }
        return out
    }

    /// For a summarizer: spell them as written, don't translate or "correct" them.
    static func spellingInstruction(_ terms: [String]) -> String? {
        terms.isEmpty ? nil
            : "Spell these names and terms exactly as written here: \(terms.joined(separator: ", "))."
    }
}

/// Which shape the notes take. One meeting is not another: a 1:1 and a sales
/// call want different things pulled out of the same transcript.
///
/// The standard template is the shape Ata has always written, word for word,
/// so choosing nothing changes nothing.
enum SummaryTemplate: String, CaseIterable, Identifiable {
    case standard
    case oneToOne = "one-to-one"
    case sales
    case standup
    case interview

    var id: String { rawValue }

    static func named(_ raw: String?) -> SummaryTemplate {
        SummaryTemplate(rawValue: raw ?? "") ?? .standard
    }

    var title: String {
        switch self {
        case .standard: return L("Standard")
        case .oneToOne: return L("One-to-one")
        case .sales: return L("Sales call")
        case .standup: return L("Team standup")
        case .interview: return L("Interview")
        }
    }

    /// One line of steering for the writer, which fills fixed fields.
    var focus: String {
        switch self {
        case .standard: return ""
        case .oneToOne:
            return "This was a one-to-one. Pay attention to how each person is doing, feedback given, and what each committed to."
        case .sales:
            return "This was a sales call. Pay attention to the customer's needs and problems, objections, budget and timeline, and the next step promised."
        case .standup:
            return "This was a team standup. Attribute updates and blockers to the person they belong to."
        case .interview:
            return "This was an interview. Pay attention to the candidate's strengths, concerns or gaps, and notable answers."
        }
    }
}

/// A follow-up email from notes Ata already wrote: the overview as the body,
/// the action items as the next steps. No second model call — the summary did
/// that work, and a draft you can paste anywhere beats one locked in a mail app.
enum FollowUp {
    static func draft(summary: String, meetingTitle: String, myName: String) -> String {
        var out = [L("Subject: Follow-up: %@", meetingTitle), "", L("Hi all,"), ""]
        let overview = sectionText(summary, heading: L("Overview"))
        if overview.isEmpty {
            out.append(L("Thanks for the meeting. Notes below."))
        } else {
            let ended = overview.hasSuffix(".") || overview.hasSuffix("!") || overview.hasSuffix("?")
            out.append(L("Thanks for the meeting. %@", ended ? overview : overview + "."))
        }
        let actions = sectionBullets(summary, heading: L("Action items"))
        if !actions.isEmpty {
            out += ["", L("Next steps:")] + actions.map { "- " + $0 }
        }
        out += ["", L("Best,"), myName]
        return out.joined(separator: "\n")
    }

    /// The overview is written on the line after its heading, after an em dash.
    static func sectionText(_ markdown: String, heading: String) -> String {
        for line in markdown.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("**\(heading)**") else { continue }
            return t.dropFirst("**\(heading)**".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "—-"))
                .trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// The "- …" lines under a heading, until the next heading or the end.
    static func sectionBullets(_ markdown: String, heading: String) -> [String] {
        var inSection = false
        var out: [String] = []
        for line in markdown.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("**") {
                inSection = t.hasPrefix("**\(heading)**")
                continue
            }
            if inSection, t.hasPrefix("- ") { out.append(String(t.dropFirst(2))) }
            else if inSection, !t.isEmpty { inSection = false }
        }
        return out
    }
}

/// Optional second pass: turns a finished transcript into a short summary with
/// decisions and action items, with Apple's on-device model. Nothing leaves the
/// device, and a failure here never fails the transcript, which is already written.
enum Summarizer {
    /// Roughly 100k characters of transcript, which is far longer than any
    /// meeting Ata is likely to see, but keeps a runaway file from stalling the model.
    private static let maxCharacters = 100_000

    /// The language the summary is written in: the app's own language, with the
    /// user's region, so a Portuguese user in Portugal gets European Portuguese
    /// rather than whatever variant the model defaults to.
    static var replyLanguage: String {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let english = Locale(identifier: "en")
        let name = english.localizedString(forLanguageCode: language) ?? "English"
        guard let region = Locale.current.region?.identifier,
              let regionName = english.localizedString(forRegionCode: region) else { return name }
        var text = "\(name) as written in \(regionName), with that country's spelling and vocabulary"
        // Models drift into Brazilian Portuguese unless told precisely.
        if language.hasPrefix("pt") && region == "PT" {
            text += " — European Portuguese, never Brazilian (\"equipa\", not \"equipe\"; \"ecrã\", " +
                "not \"tela\"; \"telemóvel\", not \"celular\"; enclitic pronouns such as \"responsabiliza-se\")"
        }
        return text
    }

    static func summarize(markdown: String, options: TranscribeOptions) async -> String? {
        guard AppleModel.isAvailable else { return nil }
        return await AppleModel.summarize(markdown: String(markdown.prefix(maxCharacters)), myName: options.myName,
                                          template: SummaryTemplate.named(options.summaryTemplate),
                                          vocabulary: options.vocabulary)
    }
}
