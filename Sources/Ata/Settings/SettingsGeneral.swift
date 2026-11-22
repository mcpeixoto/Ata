#if os(macOS)
import SwiftUI

/// Where Ata lives, login, updates, status and usage.
struct SettingsGeneralPane: View {
    @EnvironmentObject private var setup: SetupModel
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    @AppStorage(Pref.shareUsage) private var shareUsage = true
    @AppStorage(Pref.dockIcon) private var dockIcon = false
    @AppStorage(Pref.menuBarIcon) private var menuBarIcon = true

    var body: some View {
        Form {
            presenceSection
            systemSection
        }
        .settingsForm()
    }

    private var presenceSection: some View {
        Section("Where Ata lives") {
            Toggle("Show Ata in the Dock", isOn: Binding(
                get: { dockIcon }, set: { Presence.setDockIcon($0) }))
            // Only offered once the Dock icon can take its place: with no Dock
            // icon this would be a switch that does nothing, and turning it off
            // would leave Ata running with no way in.
            if dockIcon {
                Toggle("Keep the menu bar icon", isOn: $menuBarIcon)
            }
            SettingsNote(dockIcon
                 ? L("Ata is also in the Dock, and stays there when its windows close. Useful when the menu bar has no room: macOS hides the icons that don't fit.")
                 : L("Closing a window or pressing ⌘Q leaves Ata in the menu bar, ready for the next meeting. Quit Ata, in its menu, is what stops it."))
        }
    }

    private var systemSection: some View {
        Section("System") {
            Toggle("Open at login", isOn: Binding(
                get: { setup.launchAtLogin }, set: { setup.setLaunchAtLogin($0) }))
            Toggle("Check for updates automatically", isOn: $autoUpdate)
            LabeledContent("Updates") {
                UpdateControl()
            }
            LabeledContent("Status") {
                HStack {
                    if setup.ready {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Button(setup.ready ? L("Review setup") : L("Fix…")) { WindowManager.shared.showOnboarding() }
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Toggle("Share anonymous usage stats", isOn: $shareUsage)
                SettingsNote(L("Once a day: the app version, your country and how many minutes you recorded. Never your audio, transcripts or names."))
            }
        }
    }
}
#endif
