import Foundation

/// Everything the Insights tab shows, computed from the meeting folders.
struct Insights: Equatable {
    struct Week: Equatable, Identifiable {
        let start: Date
        var minutes: Double
        var meetings: Int
        var id: Date { start }
    }

    struct AppShare: Equatable, Identifiable {
        let name: String
        let minutes: Double
        var id: String { name }
    }

    struct Event: Equatable, Identifiable {
        let meetingTitle: String
        let meetingID: String
        let record: TranscriptionRecord
        /// False for a transcript that has since been replaced by a newer one.
        let isCurrent: Bool
        var id: String { meetingID + record.id }
    }

    var meetings = 0
    var recordedSeconds = 0.0
    var words = 0
    var spentThisMonth = 0.0
    var spentTotal = 0.0
    /// What the locally transcribed audio would have cost on OpenAI.
    var savedLocally = 0.0
    var mySpeech = 0.0
    var othersSpeech = 0.0
    var weeks: [Week] = []
    var apps: [AppShare] = []
    var timeline: [Event] = []

    var isEmpty: Bool { meetings == 0 }

    /// Share of speaking time that was yours, 0…1.
    var myShare: Double {
        let total = mySpeech + othersSpeech
        return total > 0 ? mySpeech / total : 0
    }

    static let weeksShown = 8

    static func compute(_ all: [Meeting], myName: String, now: Date = Date()) -> Insights {
        var out = Insights()
        let cal = Calendar.current
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now

        out.weeks = (0..<weeksShown).reversed().compactMap { back in
            cal.date(byAdding: .weekOfYear, value: -back, to: thisWeek).map { Week(start: $0, minutes: 0, meetings: 0) }
        }

        var appMinutes: [String: Double] = [:]
        for m in all where m.status != .recording {
            let seconds = m.duration ?? 0
            out.meetings += 1
            out.recordedSeconds += seconds
            appMinutes[m.title, default: 0] += seconds / 60

            if let week = cal.dateInterval(of: .weekOfYear, for: m.startedAt)?.start,
               let i = out.weeks.firstIndex(where: { $0.start == week }) {
                out.weeks[i].minutes += seconds / 60
                out.weeks[i].meetings += 1
            }

            let records = m.transcriptions ?? Backfill.record(for: m, myName: myName).map { [$0] } ?? []
            for (i, r) in records.enumerated() {
                out.spentTotal += r.costUSD
                if r.finishedAt >= monthStart { out.spentThisMonth += r.costUSD }
                if r.isLocal { out.savedLocally += Pricing.localSavings(seconds: r.audioSeconds) }
                out.timeline.append(Event(meetingTitle: m.title, meetingID: m.id, record: r,
                                          isCurrent: i == records.count - 1))
            }
            // Talk time and words describe the meeting, so only its current transcript counts.
            if let latest = records.last {
                out.words += latest.words
                out.mySpeech += latest.mySpeechSeconds
                out.othersSpeech += latest.othersSpeechSeconds
            }
        }

        out.apps = appMinutes
            .map { AppShare(name: $0.key, minutes: $0.value) }
            .sorted { $0.minutes > $1.minutes }
            .prefix(4)
            .map { $0 }
        out.timeline.sort { $0.record.finishedAt > $1.record.finishedAt }
        return out
    }
}

/// Builds an approximate record for meetings transcribed before Ata 2.2, which
/// have a transcript but no `transcriptions` entry, by reading the Markdown.
/// Nothing is written back: the meeting folders stay exactly as they were.
enum Backfill {
    private struct Cached { let modified: Date; let record: TranscriptionRecord }
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    static func record(for m: Meeting, myName: String) -> TranscriptionRecord? {
        guard m.status == .done, let url = m.existingTranscriptURL else { return nil }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)
            ?? .distantPast

        lock.lock()
        if let hit = cache[url.path], hit.modified == modified { lock.unlock(); return hit.record }
        lock.unlock()

        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var mine = 0, theirs = 0
        for line in text.split(separator: "\n") where line.hasPrefix("**") {
            // "**[01:23] Name:** words" or "**Name:** words"
            guard let close = line.range(of: ":**") else { continue }
            var speaker = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
            if speaker.hasPrefix("["), let end = speaker.firstIndex(of: "]") {
                speaker = speaker[speaker.index(after: end)...]
            }
            let count = Transcriber.wordCount(String(line[close.upperBound...]))
            if speaker.trimmingCharacters(in: .whitespaces) == myName { mine += count } else { theirs += count }
        }

        let record = TranscriptionRecord(
            engine: text.contains("OpenAI") ? Engine.openAI.rawValue : Engine.local.rawValue,
            model: L("earlier"),
            finishedAt: m.endedAt ?? m.startedAt,
            audioSeconds: (m.duration ?? 0) * 2,
            processingSeconds: 0,
            costUSD: 0,
            words: mine + theirs,
            mySpeechSeconds: Double(mine) / 2.5,
            othersSpeechSeconds: Double(theirs) / 2.5,
            archivedAs: nil)

        lock.lock(); cache[url.path] = Cached(modified: modified, record: record); lock.unlock()
        return record
    }
}
