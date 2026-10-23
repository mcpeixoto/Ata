import SwiftUI

// The views and models shared with the Mac (MeetingView, MeetingModel, InsightsView,
// PeopleView, Notifier) are compiled into this app unchanged. They talk to the
// Mac's central objects by name; on iPhone those names lead to the phone's own.

/// The meeting list, the transcription queue and recording.
typealias AppStore = PhoneStore

/// Showing a meeting or Settings: a tab and a navigation path here, not a window.
typealias WindowManager = PhoneNavigation

/// The Mac renders README screenshots offscreen; the iPhone app never does.
enum Snapshots {
    static let rendering = false
}

extension View {
    /// Escape on a Mac keyboard cancels an edit. There is no Escape on a phone,
    /// so here it is a no-op; the shared views keep their Mac behaviour.
    func onExitCommand(perform action: @escaping () -> Void) -> Self {
        self
    }
}
