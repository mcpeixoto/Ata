import Foundation

/// The one example meeting added when a library is empty, so the first launch
/// has something to open. It lives in this device's meetings folder, never in
/// iCloud, and a deletion is remembered so the next launch does not put it back.
///
/// No clip ships: system text-to-speech voices may not be redistributed in a
/// commercial app. A `weekly-sync-en.mp3` / `weekly-sync-pt.mp3` in the bundle
/// would be used if one is added (recorded by a person who agreed to it).
/// Without it the meeting still has its transcript, summary, speakers and bookmark.
enum SampleMeeting {
    static let folderID = "sample-weekly-sync"
    /// Wall-clock length of the example. The spoken clip is built to land here.
    static let seconds: Double = 78
    static let bookmarkID = UUID(uuidString: "B6C3A1E2-4F10-4C3A-9A2E-7D5B1E8C4A60")!
    /// Where the one bookmark sits, on the line about sending the copy.
    static let bookmarkMS = 38_000

    /// Nothing recorded yet, and the example has not been removed by hand.
    static func shouldInstall(meetingCount: Int, dismissed: Bool) -> Bool {
        meetingCount == 0 && !dismissed
    }

    /// This folder is the example, so a copy into iCloud leaves it out.
    static func staysOnDevice(_ folderName: String) -> Bool { folderName == folderID }

    /// True when the example was written. A second call finds it already there.
    @discardableResult
    static func installIfNeeded(defaults: UserDefaults = Pref.d) -> Bool {
        guard !Snapshots.rendering else { return false }
        return (try? install(into: Paths.localMeetingsDir, meetingCount: Library.loadAll().count,
                             defaults: defaults)) ?? false
    }

    /// `meetingCount` is how many meetings the library already has. `directory`
    /// is this device's meetings folder, which tests point at a scratch directory.
    @discardableResult
    static func install(into directory: URL, meetingCount: Int, defaults: UserDefaults) throws -> Bool {
        guard shouldInstall(meetingCount: meetingCount, dismissed: defaults.bool(forKey: Pref.sampleDismissed)) else {
            return false
        }
        let meta = directory.appendingPathComponent(folderID, isDirectory: true)
            .appendingPathComponent("meeting.json")
        if FileManager.default.fileExists(atPath: meta.path) { return false }
        try write(into: directory)
        return true
    }

    /// Remember a deletion. The folder is removed by the caller.
    static func noteDeleted(_ meeting: Meeting, defaults: UserDefaults = Pref.d) {
        guard meeting.isSample == true else { return }
        defaults.set(true, forKey: Pref.sampleDismissed)
    }

    /// Writes the example into `directory`. `audio`, when set, is copied in as
    /// meeting.mp3; otherwise the bundled clip is used if the build had one.
    @discardableResult
    static func write(into directory: URL, now: Date = Date(), audio: URL? = nil) throws -> Meeting {
        let fm = FileManager.default
        let dir = directory.appendingPathComponent(folderID, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let started = now.addingTimeInterval(-86_400)
        let ended = started.addingTimeInterval(seconds)
        var meeting = Meeting(id: folderID, startedAt: started, endedAt: ended, duration: seconds,
                              app: L("Example: weekly sync"), status: .done, error: nil)
        meeting.isSample = true
        // Not this device: retention, recovery and the free minutes all skip it.
        meeting.origin = DeviceRef(id: "ata-sample", name: "Ata", kind: "sample")
        meeting.category = CategoryTag(value: MeetingCategory.work.rawValue, manual: false, at: started)
        meeting.bookmarks = [Bookmark(id: bookmarkID, ms: bookmarkMS, note: L("Send the copy"))]

        let stored = transcript()
        let mine = stored.segments.filter { $0.speaker == Speakers.me }
        let theirs = stored.segments.filter { $0.speaker != Speakers.me }
        meeting.transcriptions = [TranscriptionRecord(
            engine: Engine.local.rawValue, model: "large-v3-q5_0", finishedAt: ended,
            audioSeconds: seconds, processingSeconds: 0, costUSD: 0,
            words: stored.segments.reduce(0) { $0 + $1.text.split(separator: " ").count },
            mySpeechSeconds: speech(mine), othersSpeechSeconds: speech(theirs), archivedAs: nil)]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try Coordinated.write(encoder.encode(meeting), to: dir.appendingPathComponent("meeting.json"))
        try stored.save(to: dir.appendingPathComponent("transcript.json"))
        try Coordinated.write(encoder.encode(speakers(in: stored)), to: dir.appendingPathComponent("speakers.json"))

        let names: (String) -> String = { label in
            label == Speakers.me ? Pref.myNameOrDefault : "Rita"
        }
        try Coordinated.write(Transcriber.render(stored, meeting: meeting, names: names),
                              to: dir.appendingPathComponent("transcript.md"))

        if let audio = audio ?? bundledAudio(), fm.fileExists(atPath: audio.path) {
            let dest = dir.appendingPathComponent("meeting.mp3")
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: audio, to: dest)
        }
        return meeting
    }

    /// The spoken clip for the current language, if this build bundled one.
    static func bundledAudio() -> URL? {
        let code = Locale.current.language.languageCode?.identifier == "pt" ? "pt" : "en"
        return audio(named: "weekly-sync-\(code)") ?? audio(named: code == "pt" ? "weekly-sync-en" : "weekly-sync-pt")
    }

    private static func audio(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sample")
            ?? Bundle.main.url(forResource: name, withExtension: "mp3")
    }

    private static func speech(_ lines: [StoredTranscript.Line]) -> Double {
        lines.reduce(0) { $0 + Double($1.end - $1.start) / 1000 }
    }

    private static func speakers(in stored: StoredTranscript) -> MeetingVoices {
        let lines = stored.segments
        return MeetingVoices(
            speakers: [
                MeetingSpeaker(label: Speakers.me, embedding: [], seconds: speech(lines.filter { $0.speaker == Speakers.me }),
                               voiceID: nil, name: nil),
                MeetingSpeaker(label: "S1", embedding: [], seconds: speech(lines.filter { $0.speaker == "S1" }),
                               voiceID: nil, name: "Rita"),
            ],
            turns: lines.map { SpeakerTurn(start: $0.start, end: $0.end, label: $0.speaker) })
    }

    /// Two people, one bookmark's worth of a weekly sync. The strings are the
    /// English keys; Portuguese comes from the strings file at the moment this
    /// is written, which is the first launch.
    private static func transcript() -> StoredTranscript {
        let lines: [(Int, Int, String, String)] = [
            (0, 8_000, Speakers.me, L("Morning. Shall we lock Friday as the launch date?")),
            (9_000, 22_000, "S1", L("Design is done. I can finish the onboarding copy by Wednesday.")),
            (24_000, 36_000, Speakers.me, L("Friday works. That gives QA two days.")),
            (38_000, 52_000, "S1", L("I'll send the copy over and update the screenshots.")),
            (54_000, 66_000, Speakers.me, L("Let's look at the numbers on Thursday.")),
            (68_000, 78_000, "S1", L("I'll book thirty minutes.")),
        ]
        return StoredTranscript(
            segments: lines.map { StoredTranscript.Line(start: $0.0, end: $0.1, text: $0.3, speaker: $0.2, words: nil) },
            coarse: false,
            summary: L("The team agreed to launch on Friday, once the onboarding copy is finished and QA has had two days."),
            engine: Engine.local.rawValue, model: "large-v3-q5_0", health: nil)
    }
}
