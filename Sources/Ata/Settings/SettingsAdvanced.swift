#if os(macOS)
import SwiftUI

/// Menu-bar icon and the extra audio files. They used to sit in a disclosure
/// at the bottom of one long form; opening this pane is that disclosure.
struct SettingsAdvancedPane: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(Pref.keepAudio) private var keepAudio = true
    @AppStorage(Pref.compressAudio) private var compressAudio = true
    @AppStorage(Pref.saveMP3) private var saveMP3 = true
    @AppStorage(Pref.menuIconSymbol) private var menuIconSymbol = MenuIcon.Symbol.dot.rawValue
    @AppStorage(Pref.menuIconTint) private var menuIconTint = MenuIcon.Tint.monochrome.rawValue
    @AppStorage(Pref.menuIconTimer) private var menuIconTimer = true
    @AppStorage(Pref.menuIconPulse) private var menuIconPulse = false
    @AppStorage(Pref.menuIconProgress) private var menuIconProgress = true

    var body: some View {
        Form {
            Section {
                menuBarRows
                Toggle("Compress kept audio to m4a", isOn: $compressAudio)
                    .disabled(!keepAudio)
                Toggle("Also save the whole meeting as one MP3", isOn: Binding(
                    get: { saveMP3 }, set: { saveMP3 = $0; if $0 { store.backfillMergedAudio() } }))
                    .disabled(!keepAudio)
            }
        }
        .settingsForm()
    }

    @ViewBuilder
    private var menuBarRows: some View {
        LabeledContent("While recording") {
            MenuIconPreview(style: MenuIcon.Style(symbol: menuIconSymbol, tint: menuIconTint,
                                                  timer: menuIconTimer, pulse: menuIconPulse))
        }
        Picker("Icon", selection: $menuIconSymbol) {
            ForEach(MenuIcon.Symbol.allCases) { symbol in
                Label(symbol.title, systemImage: symbol.systemName).tag(symbol.rawValue)
            }
        }
        Picker("Color", selection: $menuIconTint) {
            ForEach(MenuIcon.Tint.allCases) { tint in
                Text(tint.title).tag(tint.rawValue)
            }
        }
        Toggle("Show the recording time", isOn: $menuIconTimer)
        Toggle("Pulse while recording", isOn: $menuIconPulse)
        Toggle("Show transcription progress", isOn: $menuIconProgress)
    }
}
#endif
