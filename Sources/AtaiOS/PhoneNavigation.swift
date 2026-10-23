import SwiftUI

/// Which tab and which meeting are showing. The shared views ask the Mac's
/// `WindowManager` to show a meeting or Settings; on iPhone that means a tab and
/// a navigation path, so this answers to the same calls (see SharedBridges.swift).
@MainActor
final class PhoneNavigation: ObservableObject {
    static let shared = PhoneNavigation()

    enum Tab: Hashable { case record, meetings, people, insights, settings }

    @Published var tab: Tab = .record
    /// Meeting ids pushed on the Meetings tab.
    @Published var meetingPath: [String] = []
    @Published var showingOnboarding = false

    func showMeeting(_ id: String) {
        tab = .meetings
        meetingPath = [id]
    }

    func closeMeeting(_ id: String) {
        meetingPath.removeAll { $0 == id }
    }

    func showSettings() {
        tab = .settings
    }

    func showOnboarding() {
        showingOnboarding = true
    }
}
