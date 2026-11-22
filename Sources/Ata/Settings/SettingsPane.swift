#if os(macOS)
import SwiftUI

/// One page of the settings window. General keeps the README screenshot name.
enum SettingsPane: String, CaseIterable, Hashable, Identifiable {
    case general
    case recording
    case transcription
    case storage
    case pro
    case agent
    case advanced
    case about

    var id: String { rawValue }

    /// `settings` is the old full-window shot. It now shows General; the other
    /// panes are `settings-<name>`.
    var snapshotName: String {
        self == .general ? "settings" : "settings-\(rawValue)"
    }
}

extension View {
    /// Grouped form and the app's switch. The detail column scrolls this,
    /// so a pane taller than the window is still reachable.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .toggleStyle(AppSwitchStyle())
    }
}
#endif
