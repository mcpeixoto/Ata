import Foundation
#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

/// One meeting the question is asked against. `transcript` is transcript.md.
struct AskSource: Equatable {
    var id: String
    var title: String
    var transcript: String
}

/// A stretch of one meeting small enough to hand to the on-device model.
struct AskChunk: Equatable {
    var meetingID: String
    var meetingTitle: String
    var startMs: Int
    var text: String
}

/// `[Meeting title · mm:ss]` as the model is asked to write it.
struct AskCitation: Equatable {
    var title: String
    var stamp: String
    var milliseconds: Int
}

enum AskTime {
    /// `mm:ss` or `h:mm:ss`, the same shapes `Transcriber.timestamp` writes.
    /// Nil when it is not a time.
    static func milliseconds(_ stamp: String) -> Int? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ part in !part.isEmpty && part.count <= 2 && part.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 2 {
            guard numbers[1] < 60 else { return nil }
            return (numbers[0] * 60 + numbers[1]) * 1_000
        }
        guard numbers[1] < 60, numbers[2] < 60 else { return nil }
        return (numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]) * 1_000
    }
}

enum AskCitations {
    /// The middle dot the citation is written with, so the prompt and the parser
    /// cannot drift apart.
    static let separator = " · "

    static func mark(title: String, stamp: String) -> String {
        "[\(title)\(separator)\(stamp)]"
    }

    static func parse(_ text: String) -> [AskCitation] {
        var found: [AskCitation] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard let open = text[index...].firstIndex(of: "[") else { break }
            let after = text.index(after: open)
            guard after < text.endIndex, let close = text[after...].firstIndex(of: "]") else { break }
            let body = text[after..<close]
            if !body.contains("\n"), let range = body.range(of: separator) {
                let title = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let stamp = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, let ms = AskTime.milliseconds(stamp) {
                    found.append(AskCitation(title: title, stamp: stamp, milliseconds: ms))
                }
            }
            index = text.index(after: close)
        }
        return found
    }
}

/// Keyword overlap across meetings. No embeddings: a word in the question that
/// also occurs in a chunk is a hit, and the best eight that fit the model's
/// window are the ones it is shown.
enum AskIndex {
    /// Eight excerpts is as many as one answer stays readable with.
    static let maximum = 8
    /// One excerpt. A line longer than this is cut, so a monologue cannot take
    /// the whole window.
    static let chunkCharacters = 800
    /// Characters of excerpts in one reply. The on-device window is about 4,000
    /// tokens; this leaves the question and the answer room beside the excerpts.
    static let contextBudget = 4_500

    static func rank(question: String, meetings: [AskSource]) -> [AskChunk] {
        let query = tokens(question)
        guard !query.isEmpty else { return [] }
        var scored: [(chunk: AskChunk, score: Int, order: Int)] = []
        var order = 0
        for meeting in meetings {
            for chunk in chunks(of: meeting, maxCharacters: chunkCharacters) {
                let score = overlap(query, tokens(chunk.text))
                if score > 0 { scored.append((chunk, score, order)) }
                order += 1
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.order < rhs.order
        }
        var picked: [AskChunk] = []
        var used = 0
        for item in scored {
            if picked.count == maximum { break }
            if used + item.chunk.text.count > contextBudget { break }
            picked.append(item.chunk)
            used += item.chunk.text.count
        }
        return picked
    }

    static func chunks(meetings: [AskSource], maxCharacters: Int = chunkCharacters) -> [AskChunk] {
        meetings.flatMap { chunks(of: $0, maxCharacters: maxCharacters) }
    }

    static func chunks(of meeting: AskSource, maxCharacters: Int = chunkCharacters) -> [AskChunk] {
        let limit = max(1, maxCharacters)
        var chunks: [AskChunk] = []
        var buffer: [String] = []
        var count = 0
        var start = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            chunks.append(AskChunk(meetingID: meeting.id, meetingTitle: meeting.title,
                                   startMs: start, text: buffer.joined(separator: "\n")))
            buffer = []
            count = 0
        }

        for line in spokenLines(meeting.transcript) {
            let rendered = "\(line.speaker): \(line.text)"
            if count + rendered.count > limit, !buffer.isEmpty { flush() }
            var rest = Substring(rendered)
            while rest.count > limit {
                if buffer.isEmpty { start = line.startMs }
                let cut = rest.index(rest.startIndex, offsetBy: limit)
                buffer.append(String(rest[..<cut]))
                flush()
                rest = rest[cut...]
            }
            if rest.isEmpty { continue }
            if buffer.isEmpty { start = line.startMs }
            let piece = String(rest)
            // The newline `joined` inserts is part of what the next piece has to fit beside.
            if !buffer.isEmpty { count += 1 }
            buffer.append(piece)
            count += piece.count
        }
        flush()
        return chunks
    }

    private struct SpokenLine {
        var startMs: Int
        var speaker: String
        var text: String
    }

    /// `**[00:12] Rita:** words`, which is the line transcript.md writes.
    /// Headings, the footer and lines without a time are not speech.
    private static func spokenLines(_ transcript: String) -> [SpokenLine] {
        var lines: [SpokenLine] = []
        for raw in transcript.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("**["), let bracket = line.range(of: "]") else { continue }
            let stampStart = line.index(line.startIndex, offsetBy: 3)
            guard stampStart < bracket.lowerBound,
                  let ms = AskTime.milliseconds(String(line[stampStart..<bracket.lowerBound])) else { continue }
            let rest = line[bracket.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let mark = rest.range(of: ":**") else { continue }
            let speaker = rest[..<mark.lowerBound].trimmingCharacters(in: .whitespaces)
            let text = rest[mark.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !speaker.isEmpty, !text.isEmpty else { continue }
            lines.append(SpokenLine(startMs: ms, speaker: String(speaker), text: String(text)))
        }
        return lines
    }

    /// Letters and digits, case and accents folded. One letter is not a word.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func overlap(_ question: [String], _ chunk: [String]) -> Int {
        let words = Set(chunk)
        var seen = Set<String>()
        return question.reduce(0) { total, word in
            guard seen.insert(word).inserted, words.contains(word) else { return total }
            return total + 1
        }
    }
}

/// The question, the excerpts, and the citation form. Tests read this. They do
/// not call `answer`, which is the only place the on-device model is touched.
enum AskMeetings {
    struct Answer: Equatable {
        var text: String
        var citations: [AskCitation]
    }

    static func prompt(question: String, chunks: [AskChunk]) -> String {
        var lines = [
            "Answer the question using only the excerpts below. Cite each excerpt you use as [Meeting title · mm:ss], with that excerpt's meeting title and its start time. Add nothing that is not in the excerpts.",
            "",
            "Question: \(question)",
            "",
            "Excerpts:",
        ]
        for chunk in chunks {
            lines.append(AskCitations.mark(title: chunk.meetingTitle, stamp: Transcriber.timestamp(chunk.startMs)))
            lines.append(chunk.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Nil when nothing in the meetings matches, or Apple Intelligence cannot
    /// answer. The citations are the `[Title · mm:ss]` marks in the reply.
    static func answer(question: String, meetings: [AskSource]) async -> Answer? {
        let chunks = AskIndex.rank(question: question, meetings: meetings)
        guard !chunks.isEmpty, AppleModel.isAvailable else { return nil }
        let asked = prompt(question: question, chunks: chunks)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard let text = try? await AskSession.respond(to: asked) else { return nil }
            return Answer(text: text, citations: AskCitations.parse(text))
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
private enum AskSession {
    static func respond(to prompt: String) async throws -> String {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        return try await session.respond(to: prompt, options: GenerationOptions(temperature: 0.2)).content
    }

    private static var instructions: String {
        """
        You answer a question about the user's own recorded meetings. Use only the \
        excerpts you are given. Cite each excerpt you use as [Meeting title · mm:ss]. \
        Write in \(Summarizer.replyLanguage). Add nothing that is not in the excerpts.
        """
    }
}
#endif
