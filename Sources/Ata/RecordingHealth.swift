import Foundation

/// Decisions the iPhone recorder's ticker makes without a microphone: whether
/// there is room to start, whether a silent capture should be restarted, and
/// how long the Live Activity may count without hearing from the app.
enum RecordingHealth {
    /// Refuse a new recording below this. About 200 MB, so the file can grow.
    static let minimumFreeBytes: Int64 = 200_000_000
    /// No buffers for this long means the microphone has stalled.
    static let stallAfter: TimeInterval = 4
    /// No sooner than the recorder's longest retry delay, so a nudge never
    /// outruns the backoff already in progress.
    static let stallRetryAfter: TimeInterval = 5
    /// The lock-screen timer is stale unless the app has checked in within this.
    static let activityStaleAfter: TimeInterval = 2 * 60
    /// How often that check-in has to happen, including with the screen off.
    static let activityRefreshAfter: TimeInterval = 60

    /// Not knowing how much space is free is no reason to refuse.
    static func hasRoom(available: Int64?) -> Bool {
        guard let available else { return true }
        return available >= minimumFreeBytes
    }

    static func shouldRestartCapture(capturing: Bool, secondsSinceBuffer: TimeInterval,
                                     secondsSinceRestart: TimeInterval) -> Bool {
        capturing && secondsSinceBuffer > stallAfter && secondsSinceRestart >= stallRetryAfter
    }

    /// Warn, then restart. The restart clears the warning when it succeeds, so
    /// raising it afterwards left "the microphone went quiet" on screen for good.
    enum StallStep: Equatable { case warn, restart }
    static let stallRecoveryOrder: [StallStep] = [.warn, .restart]

    static func shouldRefreshActivity(secondsSinceRefresh: TimeInterval) -> Bool {
        secondsSinceRefresh >= activityRefreshAfter
    }

    static func activityStaleDate(now: Date) -> Date {
        now.addingTimeInterval(activityStaleAfter)
    }
}

/// What the record button says when starting fails. Errors Ata already wrote
/// for the user pass through; anything from the audio system becomes one sentence.
enum RecordingStartMessage {
    static func text(knownDescription: String?) -> String {
        if let knownDescription { return knownDescription }
        return L("Ata could not start recording. If you are on a call, end it and try again.")
    }
}
