import Foundation

/// The iPhone recorder's life as a pure state machine, so the awkward cases (a
/// call coming in, AirPods dropping out, the audio system restarting) are
/// decided in one place and tested without a microphone. `PhoneRecorder` feeds
/// it what iOS reports and carries out the effects it returns.
struct RecorderState: Equatable {
    enum Phase: Equatable {
        case idle
        case recording
        /// A call, Siri or another app has the microphone. The file stays open.
        case interrupted
        case stopped
    }

    enum Event: Equatable {
        case start
        case stop
        case interruptionBegan
        /// iOS hands the microphone back, and says whether carrying on is appropriate.
        case interruptionEnded(shouldResume: Bool)
        /// You asked to carry on after an interruption iOS did not hand back.
        case resume
        /// The input changed: AirPods connected or gone, a headset plugged in.
        case routeChanged
        /// The audio system restarted, and every audio object with it.
        case mediaServicesReset
    }

    enum Effect: Equatable {
        /// Set up the audio session, open the file, start capturing.
        case beginCapture
        /// Stop capturing; the file stays open.
        case pauseCapture
        /// Capture into the same file again.
        case resumeCapture
        /// A new capture chain for the new input, into the same file.
        case restartCapture
        /// Set the audio session up from scratch, then capture into the same file.
        case rebuildSession
        /// Stop capturing and close the file.
        case finishCapture
    }

    private(set) var phase: Phase = .idle
    /// Interruptions in this recording, for the log.
    private(set) var interruptions = 0
    /// The audio system restarted while interrupted: resuming must rebuild everything.
    private(set) var needsRebuild = false

    /// Audio is being written right now.
    var isCapturing: Bool { phase == .recording }
    /// A recording exists, capturing or paused by an interruption.
    var isActive: Bool { phase == .recording || phase == .interrupted }

    /// Moves to the next phase and returns what the recorder has to do. Events
    /// that make no sense in the current phase change nothing.
    mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.idle, .start), (.stopped, .start):
            phase = .recording
            interruptions = 0
            needsRebuild = false
            return [.beginCapture]

        case (.recording, .stop), (.interrupted, .stop):
            phase = .stopped
            needsRebuild = false
            return [.finishCapture]

        case (.recording, .interruptionBegan):
            phase = .interrupted
            interruptions += 1
            return [.pauseCapture]

        case (.interrupted, .interruptionEnded(shouldResume: true)), (.interrupted, .resume):
            phase = .recording
            defer { needsRebuild = false }
            return needsRebuild ? [.rebuildSession] : [.resumeCapture]

        case (.recording, .routeChanged):
            return [.restartCapture]

        case (.recording, .mediaServicesReset):
            return [.rebuildSession]

        case (.interrupted, .mediaServicesReset):
            needsRebuild = true
            return []

        default:
            // Includes an interruption that ends without asking to resume: the
            // recording waits, paused, for you to resume or stop it.
            return []
        }
    }
}
