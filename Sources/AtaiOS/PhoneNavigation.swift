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
    /// Which step a presentation opens on. The sheet's own step changes as the
    /// person moves through it; this stays put so the view is not recreated.
    @Published var onboardingStep: PhoneOnboarding.Step = .welcome
    /// Ata Pro; see `Paywall`.
    @Published var showingPaywall = false

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

    func showPaywall() {
        showingPaywall = true
    }

    func showOnboarding() {
        showOnboarding(at: .welcome)
    }

    /// Recording with the microphone denied opens on the permissions step:
    /// welcome has already been seen.
    func showOnboarding(at step: PhoneOnboarding.Step) {
        onboardingStep = step
        showingOnboarding = true
    }
}
