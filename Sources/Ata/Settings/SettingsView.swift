#if os(macOS)
import SwiftUI

/// Settings, split into panes. 700×520 is the window `WindowManager` opens.
struct SettingsView: View {
    static let width: CGFloat = 700
    static let height: CGFloat = 520
    /// The longest pane titles ("Transcription", "Armazenamento") plus an icon.
    static let sidebarWidth: CGFloat = 196

    @State private var selection: SettingsPane
    @EnvironmentObject private var setup: SetupModel

    init(pane: SettingsPane = .general) {
        _selection = State(initialValue: pane)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: Self.width, height: Self.height)
        .tint(Theme.accent)
        .onAppear {
            setup.refresh()
            CloudSync.shared.recheck()
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            identity
            Label("General", systemImage: "gearshape").tag(SettingsPane.general)
            Label("Recording", systemImage: "record.circle").tag(SettingsPane.recording)
            Label("Transcription", systemImage: "waveform").tag(SettingsPane.transcription)
            Label("Storage", systemImage: "internaldrive").tag(SettingsPane.storage)
            Label("Ata Pro", systemImage: "sparkles").tag(SettingsPane.pro)
            Label("Agent", systemImage: "link").tag(SettingsPane.agent)
            Label("Advanced", systemImage: "slider.horizontal.3").tag(SettingsPane.advanced)
            Label("About", systemImage: "info.circle").tag(SettingsPane.about)
        }
        .listStyle(.sidebar)
        .frame(width: Self.sidebarWidth)
    }

    /// The old window header. It stays visible on every pane. A list row
    /// ellipsizes to one line unless the text is allowed to wrap.
    private var identity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            AppGlyph(size: 32)
            Text("Settings")
                .ataTitle()
            Text(L("Ata %@ · everything runs on your Mac", Updater.currentVersion))
                .ataCaption()
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.xs)
        .selectionDisabled()
        .listRowSeparator(.hidden)
    }

    private var detail: some View {
        ScrollView {
            pane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pane: some View {
        switch selection {
        case .general: SettingsGeneralPane()
        case .recording: SettingsRecordingPane()
        case .transcription: SettingsTranscriptionPane()
        case .storage: SettingsStoragePane()
        case .pro: SettingsProPane()
        case .agent: SettingsAgentPane()
        case .advanced: SettingsAdvancedPane()
        case .about: SettingsAboutPane()
        }
    }
}
#endif
