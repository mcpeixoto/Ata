import Foundation

/// Who writes the summary. `Pref.summaryEngine` also allows "auto", which is
/// not an engine but a way of picking one; see `Summarizer.engine`.
enum SummaryEngine: String {
    /// Apple's on-device model. Nothing leaves the Mac.
    case apple
    /// OpenAI's chat API. The transcript text is uploaded.
    case openAI = "openai"
}

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

    /// For a transcription model: the terms as a list, which is the shape the
    /// hint is documented to take. Nil when there is nothing worth hinting.
    static func transcriptionPrompt(_ terms: [String]) -> String? {
        terms.isEmpty ? nil : terms.joined(separator: ", ")
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

    /// (heading, what goes under it) after the overview, for the writer that
    /// takes a Markdown shape. The overview always comes first.
    var sections: [(title: String, instruction: String)] {
        switch self {
        case .standard:
            return [(L("Decisions"), "one bullet per decision"),
                    (L("Action items"), "one bullet per task, starting with who it belongs to when the transcript says so"),
                    (L("Open questions"), "one bullet per question")]
        case .oneToOne:
            return [(L("Feedback and concerns"), "one bullet per thing raised, with who raised it"),
                    (L("Decisions"), "one bullet per decision"),
                    (L("Action items"), "one bullet per task, starting with who it belongs to"),
                    (L("Open questions"), "one bullet per question")]
        case .sales:
            return [(L("Needs and problems"), "one bullet per need or problem, in their words where you can"),
                    (L("Objections"), "one bullet per objection or worry, with who raised it"),
                    (L("Action items"), "one bullet per task, starting with who it belongs to and any date promised"),
                    (L("Open questions"), "one bullet per question")]
        case .standup:
            return [(L("Updates by person"), "one bullet per person: their name, then what they said"),
                    (L("Blockers"), "one bullet per blocker, with whose it is"),
                    (L("Action items"), "one bullet per task, starting with who it belongs to")]
        case .interview:
            return [(L("Strengths"), "one bullet per strength the conversation showed"),
                    (L("Concerns"), "one bullet per concern or gap"),
                    (L("Action items"), "one bullet per task, starting with who it belongs to"),
                    (L("Open questions"), "one bullet per question")]
        }
    }

    /// One line of steering for a writer that fills fixed fields instead.
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

    /// The Markdown shape, as the writer is asked for it.
    var shape: String {
        var parts = ["**\(L("Overview"))** — two or three sentences on one line."]
        for s in sections {
            parts.append("**\(s.title)**\n- \(s.instruction)")
        }
        return parts.joined(separator: "\n\n")
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
/// decisions and action items, with Apple's on-device model or OpenAI's chat API.
///
/// Available with either transcription engine — you can keep the audio local and
/// still send the text for a summary — and a failure here never fails the
/// transcript, which is already written.
enum Summarizer {
    /// Roughly 100k characters of transcript, which is far longer than any
    /// meeting Ata is likely to see, but keeps a runaway file from being uploaded.
    private static let maxCharacters = 100_000

    struct Result {
        let text: String
        let costUSD: Double
    }

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

    /// The engine for a summary, or nil when none can write one. "auto" prefers
    /// this Mac, then OpenAI; a named engine is never swapped for the other.
    static func engine(preference: String, appleAvailable: Bool, hasOpenAIKey: Bool) -> SummaryEngine? {
        switch SummaryEngine(rawValue: preference) {
        case .apple?: return appleAvailable ? .apple : nil
        case .openAI?: return hasOpenAIKey ? .openAI : nil
        case nil: return appleAvailable ? .apple : (hasOpenAIKey ? .openAI : nil)
        }
    }

    static func summarize(markdown: String, options: TranscribeOptions) async -> Result? {
        let transcript = String(markdown.prefix(maxCharacters))
        let hasKey = Keychain.has(Keychain.openAIKey)
        switch engine(preference: options.summaryEngine, appleAvailable: AppleModel.isAvailable, hasOpenAIKey: hasKey) {
        case .apple?:
            if let text = await AppleModel.summarize(markdown: transcript, myName: options.myName,
                                                     template: SummaryTemplate.named(options.summaryTemplate),
                                                     vocabulary: options.vocabulary) {
                return Result(text: text, costUSD: 0)
            }
            // Only "auto" may send the text elsewhere: choosing this Mac is a
            // promise that nothing leaves it.
            guard SummaryEngine(rawValue: options.summaryEngine) == nil, hasKey else { return nil }
            NSLog("Ata: no summary from this Mac, asking OpenAI")
            return await summarizeWithOpenAI(transcript, options: options)
        case .openAI?:
            return await summarizeWithOpenAI(transcript, options: options)
        case nil:
            return nil
        }
    }

    /// What the OpenAI summarizer is asked for. Kept apart from the call so the
    /// shape a template asks for can be tested without the network.
    static func systemPrompt(template: SummaryTemplate, vocabulary: [String], myName: String) -> String {
        var system = """
        You summarize meeting transcripts. The transcript was produced by automatic \
        speech recognition from two audio tracks, so it may contain mistakes. \
        "\(myName)" is the person recording; other speakers are labelled by name \
        or as "\(L("Others"))" / "\(L("Voice %d", 1))".

        Write the summary in \(replyLanguage). Speakers may use other languages; summarize \
        what they said in that language anyway.
        """
        if let spelling = Vocabulary.spellingInstruction(vocabulary) {
            system += "\n\n" + spelling
        }
        if !template.focus.isEmpty {
            system += "\n\n" + template.focus
        }
        system += """


        Reply with Markdown in exactly this shape, leaving out any section with nothing in it:

        \(template.shape)

        Do not invent anything that is not in the transcript. Do not add any other \
        heading and do not repeat the transcript.
        """
        return system
    }

    private static func summarizeWithOpenAI(_ transcript: String, options: TranscribeOptions) async -> Result? {
        guard let client = OpenAIClient() else { return nil }

        let system = systemPrompt(template: SummaryTemplate.named(options.summaryTemplate),
                                  vocabulary: options.vocabulary, myName: options.myName)

        do {
            let reply = try await client.complete(system: system, user: transcript, model: options.summaryModel)
            guard !reply.text.isEmpty else { return nil }
            return Result(text: reply.text,
                          costUSD: Pricing.chat(model: options.summaryModel,
                                                inputTokens: reply.inputTokens,
                                                outputTokens: reply.outputTokens))
        } catch {
            NSLog("Ata: summary failed: \(error.localizedDescription)")
            return nil
        }
    }
}
