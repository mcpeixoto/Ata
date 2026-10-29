import Foundation

/// How a transcription run ends, on the Mac and on the iPhone alike: what it
/// saves, decided against meeting.json as it is now rather than as it was when
/// the run began.
///
/// With the library in iCloud the other device may have renamed the meeting,
/// linked an event, or taken the run over while this one was away. Only the
/// run's own result is written onto the fresh copy, and nothing is written while
/// meeting.json is still in iCloud: a takeover looks exactly like that until the
/// file arrives.
enum RunEnd {
    /// meeting.json as this device can read it.
    enum Fresh: Equatable {
        case meeting(Meeting)
        /// Deleted meanwhile; never brought back.
        case gone
        /// Still in iCloud after waiting for it.
        case unknown
    }

    /// How long a run waits for a meeting.json that is still in iCloud before it
    /// gives up and leaves the meeting for later.
    static let metaTimeout: TimeInterval = 60

    /// After the audio didn't arrive from iCloud: how long before this device
    /// tries the meeting again, so the queue doesn't wait on it every time round.
    static let retryAfter: TimeInterval = 10 * 60

    /// meeting.json as it is now. One that is still in iCloud is asked for and
    /// waited on, up to `timeout`.
    static func fresh(_ id: String, timeout: TimeInterval = metaTimeout,
                      load: (String) -> Meeting? = Library.load,
                      download: ([URL], TimeInterval) async -> Bool = { await CloudFiles.download($0, timeout: $1) })
        async -> Fresh {
        guard let first = load(id) else { return .gone }
        guard first.isPlaceholder else { return .meeting(first) }
        _ = await download([first.metaURL], timeout)
        guard let again = load(id) else { return .gone }
        return again.isPlaceholder ? .unknown : .meeting(again)
    }

    /// What the run saves: the fresh copy with `status` and whatever `apply`
    /// sets, or nil when the run may not save at all — deleted, taken over by
    /// another device, a failure over a finished transcript, or still unknown.
    static func outcome(_ status: Meeting.Status, over fresh: Fresh, by device: DeviceRef,
                        apply: (inout Meeting) -> Void = { _ in }) -> Meeting? {
        guard case .meeting(var m) = fresh, Meeting.mayFinish(status, over: m, by: device) else { return nil }
        m.status = status
        apply(&m)
        return m
    }

    /// Reads meeting.json fresh, applies the run's result and saves it. Returns
    /// what was saved, or nil when nothing was, and then neither the meeting nor
    /// its audio may be touched. A meeting.json that never arrived leaves the
    /// meeting for this device to pick up again (see `awaits`).
    @MainActor
    static func save(_ id: String, as status: Meeting.Status, by device: DeviceRef = Device.current,
                     apply: (inout Meeting) -> Void = { _ in }) async -> Meeting? {
        let fresh = await fresh(id)
        if fresh == .unknown {
            NSLog("Ata: meeting.json of \(id) is still in iCloud; nothing saved, the meeting waits")
            orphans.withLock { _ = $0.insert(id) }
        }
        guard let m = outcome(status, over: fresh, by: device, apply: apply) else { return nil }
        Library.save(m)
        orphans.withLock { _ = $0.remove(id) }
        return m
    }

    /// The finished transcript's fields: its record in the history, no error,
    /// and the claim given up. Everything else stays as the fresh copy has it.
    static func done(_ outcome: TranscriptionOutcome) -> (inout Meeting) -> Void {
        { m in
            var history = m.transcriptions ?? []
            if let archived = outcome.archivedPrevious, !history.isEmpty {
                history[history.count - 1].archivedAs = archived
            }
            history.append(outcome.record)
            m.transcriptions = history
            m.error = nil
            m.claim = nil
        }
    }

    // MARK: Waiting

    /// The audio, or the earlier transcript, is still in iCloud: not a failure of
    /// the meeting. It goes back in the queue with the claim given up, so the
    /// device that has the audio can do it, and this one tries again later.
    static func releasesClaim(_ error: Error) -> Bool {
        switch error as? CloudFiles.Failure {
        case .notDownloaded?, .transcriptNotDownloaded?: return true
        case nil: return false
        }
    }

    /// Runs whose meeting.json was still in iCloud when they ended. Still claimed
    /// by this device, and transcribed again once meeting.json is here.
    private static let orphans = LockedValue<Set<String>>([])
    /// Meetings whose audio didn't arrive, and when they may be tried again.
    private static let waiting = LockedValue<[String: Date]>([:])

    static func retryLater(_ id: String, now: Date = Date()) {
        waiting.withLock { $0[id] = now.addingTimeInterval(retryAfter) }
    }

    static func isWaiting(_ id: String, now: Date = Date()) -> Bool {
        waiting.withLock { ($0[id] ?? .distantPast) > now }
    }

    /// The queue's test: waiting for a transcript this device may make now
    /// (`Meeting.awaitsTranscript`), unless its audio has only just failed to
    /// arrive; or a run of this device's that ended while meeting.json was in iCloud.
    static func awaits(_ m: Meeting, now: Date = Date(), by device: DeviceRef = Device.current) -> Bool {
        if isWaiting(m.id, now: now) { return false }
        if m.awaitsTranscript(now: now, by: device) { return true }
        return !m.isPlaceholder && m.status == .transcribing && m.isClaimed(by: device)
            && orphans.withLock { $0.contains(m.id) }
    }

    /// For tests: a run of `id` ended without knowing.
    static func markOrphan(_ id: String) {
        orphans.withLock { _ = $0.insert(id) }
    }
}
