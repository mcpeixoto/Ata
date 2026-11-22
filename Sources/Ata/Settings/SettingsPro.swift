#if os(macOS)
import SwiftUI

/// The Mac Pro status Track 2 showed at the top of the old form.
struct SettingsProPane: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var access = ProAccess.shared
    @ObservedObject private var licence = LicenceStore.shared

    var body: some View {
        Form {
            Section("Ata Pro") {
                Text(verbatim: ProStatus.line(
                    licenceActive: licence.isActive,
                    licenceExpires: licence.expiresAt,
                    viaPhone: access.sources.contains(.iCloudMirror) || access.sources.contains(.storeKit),
                    used: store.freeUsed,
                    limit: FreeQuota.limitMinutes))
                    .ataBody()
                    .fixedSize(horizontal: false, vertical: true)
                if !access.isPro {
                    Button("Upgrade") { WindowManager.shared.showPro(trigger: .settings) }
                }
                if MacProOffer.isConfigured && !licence.isActive {
                    Button("Enter licence key") {
                        WindowManager.shared.showPro(trigger: .settings, enterKey: true)
                    }
                }
                if licence.isActive {
                    Button("Deactivate") { Task { await licence.deactivate() } }
                }
            }
        }
        .settingsForm()
    }
}
#endif
