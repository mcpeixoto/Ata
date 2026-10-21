import Foundation

/// Optional second pass: turns a finished transcript into a short summary with
/// decisions and action items, using OpenAI's chat API.
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

    static func summarize(markdown: String, options: TranscribeOptions) async -> Result? {
        guard let client = OpenAIClient() else { return nil }

        let transcript = String(markdown.prefix(maxCharacters))
        let system = """
        You summarize meeting transcripts. The transcript was produced by automatic \
        speech recognition from two audio tracks, so it may contain mistakes. \
        "\(options.myName)" is the person recording; other speakers are labelled by name \
        or as "\(L("Others"))" / "\(L("Voice %d", 1))".

        Write the summary in \(replyLanguage). Speakers may use other languages; summarize \
        what they said in that language anyway.

        Reply with Markdown in exactly this shape, leaving out any section with nothing in it:

        **\(L("Overview"))** — two or three sentences on one line.

        **\(L("Decisions"))**
        - one bullet per decision

        **\(L("Action items"))**
        - one bullet per task, starting with who it belongs to when the transcript says so

        **\(L("Open questions"))**
        - one bullet per question

        Do not invent anything that is not in the transcript. Do not add any other \
        heading and do not repeat the transcript.
        """

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
