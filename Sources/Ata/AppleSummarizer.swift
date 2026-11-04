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

    /// What can be done about Apple Intelligence on this device right now.
    static var state: AppleIntelligenceState {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) { return AppleSummarizer.state }
        #endif
        return .unsupported
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
    static func summarize(markdown: String, myName: String,
                          template: SummaryTemplate = .standard, vocabulary: [String] = []) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return await AppleSummarizer.summarize(markdown: markdown, myName: myName,
                                                   template: template, vocabulary: vocabulary)
        }
        #endif
        return nil
    }
}

/// The pure half of a summary: what the model is given, what is kept of its replies,
/// and the one Markdown shape they end up in.
///
/// Measured on real meetings: asked for decisions, tasks and open questions, this
/// model fills all of them, inventing what it can't find, so it is asked only for
/// what was said. Its replies are joined here rather than by another model call,
/// which lost detail and let invented items through.
enum SummaryNotes {
    struct Part: Equatable {
        var topic: String
        var points: [String]
    }

    /// Enough to read in a minute. A long meeting can exceed it, by `minPerPart` a part.
    static let targetKeyPoints = 20
    private static let minPerPart = 2
    private static let maxOverviewSentences = 3
    private static let maxPointCharacters = 240
    private static let shingleWords = 5

    /// The spoken lines, as "Name: words". The header and footer aren't conversation,
    /// and timestamps and bold cost tokens the small window can't spare.
    static func conversation(from markdown: String) -> String {
        var text = markdown
        if let start = text.range(of: "\n---\n") {
            text = String(text[start.upperBound...])
            if let end = text.range(of: "\n---\n", options: .backwards) {
                text = String(text[..<end.lowerBound])
            }
        }
        return text
            .replacingOccurrences(of: #"\*\*\[\d+:\d+(:\d+)?\] ([^*]+?):\*\*"#, with: "$2:", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A reply is a topic line and then the points. Models add bullets, bold and a
    /// "Topic:" label of their own, in whatever language they are writing.
    static func part(fromReply reply: String, of piece: String) -> Part {
        let lines = reply.split(whereSeparator: \.isNewline).map(cleaned).filter { !$0.isEmpty }
        guard let first = lines.first else { return Part(topic: "", points: []) }
        return Part(topic: unlabelled(first), points: lines.dropFirst().filter { !isPasted($0, from: piece) })
    }

    /// The first few sentences of a reply. Asked for two, it sometimes writes a page,
    /// and the later sentences are where it starts making things up.
    static func overview(fromReply reply: String) -> String {
        let text = reply.split(whereSeparator: \.isNewline).map(cleaned).filter { !$0.isEmpty }.joined(separator: " ")
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, stop in
            if let sentence { sentences.append(sentence.trimmingCharacters(in: .whitespaces)) }
            if sentences.count == maxOverviewSentences { stop = true }
        }
        return sentences.joined(separator: " ")
    }

    /// This model sometimes answers with a stretch of the transcript instead of a
    /// point about it. Quoting a phrase is fine; a point that is mostly a copy is not.
    static func isPasted(_ point: String, from piece: String) -> Bool {
        if point.count > maxPointCharacters { return true }
        let source = words(piece)
        // `Sam: "Sounds good."` A label and a short quote, too short to measure below.
        if let colon = point.firstIndex(of: ":"), point.distance(from: point.startIndex, to: colon) <= 20 {
            let quoted = words(String(point[point.index(after: colon)...]))
            if !quoted.isEmpty, quoted.count < shingleWords + 3, appears(quoted, in: source) { return true }
        }
        let said = words(point)
        guard said.count >= shingleWords + 3 else { return false }
        let copiedFrom = shingles(source)
        let copied = shingles(said).filter(copiedFrom.contains).count
        return Double(copied) / Double(said.count - shingleWords + 1) >= 0.7
    }

    /// Every part gets a share, so the end of a meeting isn't crowded out by its
    /// start. Repeats go first: this model can get stuck saying one thing over and over.
    static func keyPoints(_ parts: [Part]) -> [String] {
        let share = max(minPerPart, targetKeyPoints / max(1, parts.count))
        return withoutRepeats(parts.flatMap { Array(withoutRepeats($0.points).prefix(share)) })
    }

    static func markdown(overview: String, points: [String], skippedPart: Bool) -> String {
        var sections: [String] = []
        if !overview.isEmpty { sections.append("**\(L("Overview"))** — \(overview)") }
        if !points.isEmpty {
            sections.append("**\(L("Key points"))**\n" + points.map { "- " + $0 }.joined(separator: "\n"))
        }
        if skippedPart, !sections.isEmpty { sections.append(L("Part of this conversation could not be summarized.")) }
        return sections.joined(separator: "\n\n")
    }

    private static func withoutRepeats(_ points: [String]) -> [String] {
        var kept: [String] = []
        for point in points where !kept.contains(where: { saySameThing($0, point) }) { kept.append(point) }
        return kept
    }

    /// Mostly the same long words, so "120 hours" and "100 hours" count as one thought.
    private static func saySameThing(_ a: String, _ b: String) -> Bool {
        let x = longWords(a), y = longWords(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }

    private static func longWords(_ text: String) -> Set<String> {
        Set(words(text).filter { $0.count > 3 && !$0.allSatisfy(\.isNumber) })
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    private static func appears(_ wanted: [String], in words: [String]) -> Bool {
        guard wanted.count <= words.count else { return false }
        return (0...(words.count - wanted.count)).contains { words[$0..<($0 + wanted.count)].elementsEqual(wanted) }
    }

    private static func shingles(_ words: [String]) -> Set<ArraySlice<String>> {
        guard words.count >= shingleWords else { return [] }
        return Set((0...(words.count - shingleWords)).map { words[$0..<($0 + shingleWords)] })
    }

    private static func cleaned(_ line: Substring) -> String {
        var text = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "• ", "* "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return text.replacingOccurrences(of: #"^\d+[.)] +"#, with: "", options: .regularExpression)
    }

    /// "Tema: Férias" is "Férias". A longer start before a colon is the sentence itself.
    private static func unlabelled(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":"), !line[..<colon].contains(" "),
              line.distance(from: line.startIndex, to: colon) <= 12 else { return line }
        let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? String(line[..<colon]) : rest
    }
}

/// Cuts a transcript into pieces small enough for the on-device model, whose
/// context window is only about 4,000 tokens for instructions, text and reply.
enum SummaryChunks {
    /// Contiguous pieces that join back into exactly `transcript`. Cuts only
    /// between lines, unless one line alone is longer than `maxCharacters`.
    static func split(_ transcript: String, maxCharacters: Int = 4500) -> [String] {
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

/// What can be done about Apple Intelligence here. Nothing can ask for it: an app
/// can only read this and open the pane where it is turned on.
enum AppleIntelligenceState: Equatable {
    case ready, off, preparing, unsupported
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
enum AppleSummarizer {
    static var state: AppleIntelligenceState {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: return writesAppLanguage(model) ? .ready : .unsupported
        case .unavailable(.modelNotReady): return .preparing
        case .unavailable(.appleIntelligenceNotEnabled): return .off
        case .unavailable: return .unsupported
        }
    }

    static var unavailableReason: String? {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return writesAppLanguage(model) ? nil : L("Apple Intelligence does not write summaries in this language yet.")
        case .unavailable(.modelNotReady):
            return L("Apple Intelligence is still getting ready.")
        case .unavailable(.appleIntelligenceNotEnabled):
            #if os(iOS)
            return L("Turn on Apple Intelligence in Settings to use it.")
            #else
            return L("Turn on Apple Intelligence in System Settings to use it.")
            #endif
        case .unavailable:
            #if os(iOS)
            return L("This iPhone does not support Apple Intelligence.")
            #else
            return L("This Mac does not support Apple Intelligence.")
            #endif
        }
    }

    /// The summary is written in the app's language (see `Summarizer.replyLanguage`),
    /// so that is the one the model has to support.
    private static func writesAppLanguage(_ model: SystemLanguageModel) -> Bool {
        let code = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en").language.languageCode
        return model.supportedLanguages.contains { $0.languageCode == code }
    }

    /// One set of notes per piece of the conversation, joined here. A piece the model
    /// refuses is left out and the summary says so, rather than the meeting getting none.
    static func summarize(markdown: String, myName: String, maxCharacters: Int = 4500,
                          template: SummaryTemplate = .standard, vocabulary: [String] = []) async -> String? {
        guard unavailableReason == nil else { return nil }
        do {
            return try await attempt(markdown: markdown, myName: myName, maxCharacters: maxCharacters,
                                     template: template, vocabulary: vocabulary)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize where maxCharacters > 1500 {
            // The window counts tokens and this counts characters, so a dense
            // stretch can overflow it. Smaller pieces fit.
            return await summarize(markdown: markdown, myName: myName, maxCharacters: maxCharacters / 2,
                                   template: template, vocabulary: vocabulary)
        } catch {
            NSLog("Ata: summary on this Mac failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func attempt(markdown: String, myName: String, maxCharacters: Int,
                                template: SummaryTemplate, vocabulary: [String]) async throws -> String? {
        let instructions = partInstructions(myName: myName, template: template, vocabulary: vocabulary)
        var parts: [SummaryNotes.Part] = []
        var skippedPart = false
        for piece in SummaryChunks.split(SummaryNotes.conversation(from: markdown), maxCharacters: maxCharacters) {
            do {
                var part = SummaryNotes.part(fromReply: try await respond(to: piece, instructions: instructions), of: piece)
                if part.points.isEmpty {
                    // Nothing but pasted transcript, usually: a second try often does better.
                    part = SummaryNotes.part(fromReply: try await respond(to: piece, instructions: instructions + retryReminder), of: piece)
                }
                if part.points.isEmpty { skippedPart = true } else { parts.append(part) }
            } catch LanguageModelSession.GenerationError.guardrailViolation {
                skippedPart = true
            } catch LanguageModelSession.GenerationError.refusal {
                skippedPart = true
            }
        }
        guard !parts.isEmpty else { return nil }
        let overview = await overview(of: parts, maxCharacters: maxCharacters, vocabulary: vocabulary)
        let text = SummaryNotes.markdown(overview: overview, points: SummaryNotes.keyPoints(parts), skippedPart: skippedPart)
        return text.isEmpty ? nil : text
    }

    /// The topics are a plainer overview than none, if this call fails.
    private static func overview(of parts: [SummaryNotes.Part], maxCharacters: Int, vocabulary: [String]) async -> String {
        let notes = parts.map { part in
            ([part.topic] + part.points.map { "- " + $0 }).joined(separator: "\n")
        }.joined(separator: "\n\n")
        let reply = try? await respond(to: String(notes.prefix(maxCharacters)),
                                       instructions: overviewInstructions(vocabulary: vocabulary))
        let written = SummaryNotes.overview(fromReply: reply ?? "")
        return written.isEmpty ? parts.map(\.topic).filter { !$0.isEmpty }.joined(separator: "; ") : written
    }

    /// A fresh session for every call: the context window is small, and earlier pieces
    /// must not pile up in it. Plain text under the permissive guardrails: these are the
    /// user's own conversations, and with the default ones, swearing alone gets a piece
    /// refused, which measured often enough to lose whole meetings. The low temperature
    /// is for fewer inventions.
    private static func respond(to prompt: String, instructions: String) async throws -> String {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2)).content
    }

    private static func partInstructions(myName: String, template: SummaryTemplate = .standard,
                                         vocabulary: [String] = []) -> String {
        var text = """
        You take notes on one part of a recorded conversation between people who know each \
        other. It may be a work meeting, a planning session or a family phone call. \
        "\(myName)" is the person recording.

        The text comes from automatic speech recognition. Words can be wrong, speaker names \
        can be wrong, and sometimes only one side of a call was recorded. When a phrase makes \
        no sense, leave it out rather than guess what it meant. Never add an amount, date, \
        name or reason that is not in the text. Advice from one person is not a task for another.

        Write in \(Summarizer.replyLanguage). Speakers may use other languages; write about \
        what they said in that language anyway.
        """
        // The template steers what it notices, and the dictionary how names are spelled.
        if !template.focus.isEmpty { text += "\n\n" + template.focus }
        if let spelling = Vocabulary.spellingInstruction(vocabulary) { text += "\n\n" + spelling }
        text += "\n\nReply with one line saying the topic, then up to five short bullet points of what was actually said, in your own words. Never copy lines of the text."
        return text
    }

    private static let retryReminder = "\n\nThe text may be one long speech by one person. Each bullet point must be one short sentence of your own about it, not a quotation."

    private static func overviewInstructions(vocabulary: [String]) -> String {
        var text = """
        You are given notes on consecutive parts of one conversation. In two sentences, say what \
        the whole conversation covered, mentioning every part once. Write in \(Summarizer.replyLanguage). \
        Add nothing that is not in the notes. Reply with only those two sentences.
        """
        if let spelling = Vocabulary.spellingInstruction(vocabulary) { text += "\n\n" + spelling }
        return text
    }
}
#endif
