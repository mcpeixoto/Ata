import ActivityKit
import Foundation

/// The recording on the lock screen and in the Dynamic Island, with Stop and
/// Bookmark buttons. Recording from an intent in the background is only allowed
/// while one of these is showing.
@MainActor
final class LiveRecordingActivity {
    private var activity: Activity<RecordingActivityAttributes>?
    private var state: RecordingActivityAttributes.ContentState?

    /// Activities left over from a recording the app never got to end.
    func endLeftovers() {
        for leftover in Activity<RecordingActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(mode: RecordingMode) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RecordingActivityAttributes.ContentState(timerStart: Date(), isPaused: false,
                                                             pausedSeconds: 0, bookmarks: 0)
        do {
            activity = try Activity.request(attributes: RecordingActivityAttributes(mode: mode),
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
            self.state = state
        } catch {
            NSLog("Ata: no Live Activity for this recording: \(error.localizedDescription)")
        }
    }

    /// `recorded` is the audio so far: the timer restarts from there after an interruption.
    func update(recorded: Double, paused: Bool, bookmarks: Int) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(timerStart: Date().addingTimeInterval(-recorded),
                                                             isPaused: paused, pausedSeconds: recorded,
                                                             bookmarks: bookmarks)
        guard state.isPaused != self.state?.isPaused || state.bookmarks != self.state?.bookmarks else { return }
        self.state = state
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        state = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
