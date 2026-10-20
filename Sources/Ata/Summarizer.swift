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

    static func summarize(markdown: String, options: TranscribeOptions) async -> String? {
        guard let client = OpenAIClient() else { return nil }

        let transcript = String(markdown.prefix(maxCharacters))
        let system = """
        You summarize meeting transcripts. The transcript was produced by automatic \
        speech recognition from two audio tracks, so it may contain mistakes and the \
        speaker labels are only "\(options.myName)" (the person recording) and \
        "\(L("Others"))" (everyone else).

        Reply in the same language the transcript is written in. Reply with Markdown \
        using exactly these sections, and omit a section when it has no content:

        **\(L("Overview"))** — two or three sentences.
        **\(L("Decisions"))** — bullet list.
        **\(L("Action items"))** — bullet list, each line naming who it belongs to when \
        the transcript says so.
        **\(L("Open questions"))** — bullet list.

        Do not invent anything that is not in the transcript. Do not add a heading \
        above these sections and do not repeat the transcript.
        """

        do {
            let text = try await client.complete(system: system, user: transcript, model: options.summaryModel)
            return text.isEmpty ? nil : text
        } catch {
            NSLog("Ata: summary failed: \(error.localizedDescription)")
            return nil
        }
    }
}
