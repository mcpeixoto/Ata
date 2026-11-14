import Foundation

/// Why a new recording did not start: this month's free meetings are used.
/// The words Siri speaks are `errorDescription`, added where the app can see `L()`.
enum FreeQuotaError: Error, Equatable {
    case limitReached
}

/// The gate at the start of a recording. At the free limit it throws and does
/// not record.
enum RecordingStart {
    static func begin(needsPro: Bool, record: () throws -> Void) throws {
        if needsPro { throw FreeQuotaError.limitReached }
        try record()
    }
}

/// Whether a blocked start may arm the paywall or the microphone message.
/// Arming either while Ata stays in the background makes the sheet appear
/// later, with nothing to explain it.
enum BlockedStartPresentation: Equatable {
    case showNow
    case doNotArm
}

enum BlockedStart {
    static func presentation(appIsActive: Bool, becomingForeground: Bool) -> BlockedStartPresentation {
        if appIsActive || becomingForeground { return .showNow }
        return .doNotArm
    }
}

/// What happens to the transcription queue when a recording starts or stops,
/// and when iOS ends the background task. Both pauses cancel the running job;
/// that cancellation saves the meeting back as pending. Stopping resumes the queue.
enum RecordingQueue {
    enum Event: Equatable {
        case recordingWillStart
        case recordingStopped
        case backgroundExpired
    }

    struct Decision: Equatable {
        var queuePaused: Bool
        var cancelJob: Bool
        /// The in-flight meeting goes back to pending. Cancelling the job does it.
        var savesMeetingAsPending: Bool
    }

    static func decide(_ event: Event, jobRunning: Bool) -> Decision {
        switch event {
        case .recordingWillStart, .backgroundExpired:
            return Decision(queuePaused: true, cancelJob: jobRunning, savesMeetingAsPending: jobRunning)
        case .recordingStopped:
            return Decision(queuePaused: false, cancelJob: false, savesMeetingAsPending: false)
        }
    }
}
