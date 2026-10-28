import Foundation
#if canImport(FoundationModels)
// Weak, so Ata (and its test bundle) still load on macOS 14 and 15, which have no
// FoundationModels; everything that touches it is behind @available(macOS 26.0, iOS 26.0, *).
@_weakLinked import FoundationModels
#endif

/// Apple's on-device model (Apple Intelligence), for summaries that never leave
/// the Mac. Safe to call on every macOS version: before macOS 26, or when the SDK
/// has no FoundationModels, it is simply never available.
enum AppleModel {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return AppleSummarizer.unavailableReason == nil }
        #endif
        return false
    }

    /// Why the model can't be used right now, for a footnote in Settings; nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return AppleSummarizer.unavailableReason }
        #endif
        #if os(iOS)
        return L("Needs Apple Intelligence turned on in Settings.")
        #else
        return L("Needs macOS 26 with Apple Intelligence turned on.")
        #endif
    }

    /// The summary as Markdown, or nil when the model is unavailable, does not
    /// write the app's language, or fails, so the caller can fall back.
    static func summarize(markdown: String, myName: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return await AppleSummarizer.summarize(markdown: markdown, myName: myName)
        }
        #endif
        return nil
    }
}

/// The summary in the shape `Summarizer` asks OpenAI for, so a summary reads the
/// same whoever wrote it.
enum SummaryMarkdown {
    static func render(overview: String, decisions: [String], actionItems: [String],
                       openQuestions: [String]) -> String {
        var sections: [String] = []
        let summary = oneLine(overview)
        if !summary.isEmpty {
            sections.append("**\(L("Overview"))** — \(summary)")
        }
        let lists: [(String, [String])] = [(L("Decisions"), decisions), (L("Action items"), actionItems),
                                           (L("Open questions"), openQuestions)]
        for (title, items) in lists {
            let bullets = items.map(item).filter { !$0.isEmpty }
            guard !bullets.isEmpty else { continue }
            sections.append("**\(title)**\n" + bullets.map { "- " + $0 }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Models sometimes put their own bullet in front of a list item.
    private static func item(_ text: String) -> String {
        var t = oneLine(text)
        for marker in ["- ", "• ", "* "] where t.hasPrefix(marker) {
            t = String(t.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}

/// Cuts a transcript into pieces small enough for the on-device model, whose
/// context window is only about 4,000 tokens for instructions, text and reply.
enum SummaryChunks {
    /// Contiguous pieces that join back into exactly `transcript`. Cuts only
    /// between lines, unless one line alone is longer than `maxCharacters`.
    static func split(_ transcript: String, maxCharacters: Int = 6000) -> [String] {
        let limit = max(1, maxCharacters)
        var chunks: [String] = []
        var current = ""
        var currentCount = 0

        var start = transcript.startIndex
        while start < transcript.endIndex {
            let end = transcript[start...].firstIndex(of: "\n").map { transcript.index(after: $0) }
                ?? transcript.endIndex
            var line = transcript[start..<end]
            start = end

            let count = line.count
            if currentCount + count > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentCount = 0
            }
            if count > limit {
                // No line boundary to cut at: cut the line itself.
                while line.count > limit {
                    let cut = line.index(line.startIndex, offsetBy: limit)
                    chunks.append(String(line[..<cut]))
                    line = line[cut...]
                }
                current = String(line)
                currentCount = line.count
            } else {
                current.append(contentsOf: line)
                currentCount += count
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

#if canImport(FoundationModels)
/// What the model fills in. Ata writes the Markdown itself from this, so the
/// shape never depends on the model following formatting instructions.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct MeetingSummary {
    @Guide(description: "Two or three sentences on what the meeting was about and where it ended up.")
    var overview: String
    @Guide(description: "Each decision the participants made, one per item. Empty when nothing was decided.")
    var decisions: [String]
    @Guide(description: "Each task someone took on, one per item, starting with who it belongs to when the transcript says so.")
    var actionItems: [String]
    @Guide(description: "Each question that was left unanswered, one per item.")
    var openQuestions: [String]
}

@available(macOS 26.0, iOS 26.0, *)
enum AppleSummarizer {
    static var unavailableReason: String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return writesAppLanguage(model) ? nil : L("Apple Intelligence does not write summaries in this language yet.")
        case .unavailable(.modelNotReady):
            return L("Apple Intelligence is still getting ready.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return L("Turn on Apple Intelligence in System Settings to use it.")
        case .unavailable:
            return L("This Mac does not support Apple Intelligence.")
        }
    }

    /// The summary is written in the app's language (see `Summarizer.replyLanguage`),
    /// so that is the one the model has to support.
    private static func writesAppLanguage(_ model: SystemLanguageModel) -> Bool {
        let code = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en").language.languageCode
        return model.supportedLanguages.contains { $0.languageCode == code }
    }

    /// Map–reduce: one partial summary per chunk, then the partials merged
    /// until one is left. A transcript that will not fit in a few rounds gives
    /// nil rather than a summary of only part of the meeting.
    static func summarize(markdown: String, myName: String, maxCharacters: Int = 6000) async -> String? {
        guard unavailableReason == nil else { return nil }
        do {
            var partials: [MeetingSummary] = []
            for chunk in SummaryChunks.split(markdown, maxCharacters: maxCharacters) {
                let partial = try await respond(to: chunk, instructions: chunkInstructions(myName: myName))
                partials.append(partial)
            }
            var rounds = 0
            while partials.count > 1 {
                rounds += 1
                guard rounds <= 3 else { return nil }
                let notes = partials.map(rendered).joined(separator: "\n\n")
                var merged: [MeetingSummary] = []
                for chunk in SummaryChunks.split(notes, maxCharacters: maxCharacters) {
                    let partial = try await respond(to: chunk, instructions: mergeInstructions)
                    merged.append(partial)
                }
                partials = merged
            }
            guard let text = partials.first.map(rendered), !text.isEmpty else { return nil }
            return text
        } catch {
            NSLog("Ata: summary on this Mac failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func rendered(_ s: MeetingSummary) -> String {
        SummaryMarkdown.render(overview: s.overview, decisions: s.decisions,
                               actionItems: s.actionItems, openQuestions: s.openQuestions)
    }

    /// A fresh session for every call: the context window is small, and earlier
    /// chunks must not pile up in it.
    private static func respond(to prompt: String, instructions: String) async throws -> MeetingSummary {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: MeetingSummary.self)
        return response.content
    }

    private static func chunkInstructions(myName: String) -> String {
        """
        You summarize a meeting transcript, or one part of a longer one. It was produced by \
        automatic speech recognition, so it may contain mistakes. "\(myName)" is the person \
        recording; other speakers are labelled by name or as "\(L("Others"))" / "\(L("Voice %d", 1))".

        Write in \(Summarizer.replyLanguage). Speakers may use other languages; summarize what \
        they said in that language anyway.

        Only include what the transcript says. Leave a list empty when there is nothing for it.
        """
    }

    private static var mergeInstructions: String {
        """
        You are given notes on consecutive parts of one meeting. Combine them into notes on the \
        whole meeting. Write in \(Summarizer.replyLanguage).

        Merge items that say the same thing, keep every distinct decision, task and question, \
        and drop a question that a later part answers. Do not add anything that is not in the notes.
        """
    }
}
#endif
