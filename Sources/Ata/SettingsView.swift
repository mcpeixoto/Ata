import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @StateObject private var updater = Updater.shared

    @AppStorage(Pref.autoDetect) private var autoDetect = true
    @AppStorage(Pref.autoStart) private var autoStart = false
    @AppStorage(Pref.autoStop) private var autoStop = true
    @AppStorage(Pref.keepAudio) private var keepAudio = true
    @AppStorage(Pref.compressAudio) private var compressAudio = true
    @AppStorage(Pref.saveMP3) private var saveMP3 = true
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.engine) private var engine = Engine.local.rawValue
    @AppStorage(Pref.openAIModel) private var openAIModel = Pref.defaultOpenAIModel
    @AppStorage(Pref.summarize) private var summarize = false
    @AppStorage(Pref.summaryModel) private var summaryModel = Pref.defaultSummaryModel
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    @AppStorage(Pref.audioRetentionDays) private var audioRetentionDays = 0
    @AppStorage(Pref.menuIconSymbol) private var menuIconSymbol = MenuIcon.Symbol.dot.rawValue
    @AppStorage(Pref.menuIconTint) private var menuIconTint = MenuIcon.Tint.monochrome.rawValue
    @AppStorage(Pref.menuIconTimer) private var menuIconTimer = true
    @AppStorage(Pref.menuIconPulse) private var menuIconPulse = false
    @AppStorage(Pref.menuIconProgress) private var menuIconProgress = true

    @State private var apiKey = ""

    /// The window's height. Only the snapshot renderer asks for a taller one.
    var height: CGFloat = 660

    private var usesOpenAI: Bool { engine == Engine.openAI.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                recordingSection
                menuBarSection
                transcriptionSection
                if usesOpenAI || summarize { openAISection }
                audioSection
                systemSection
                aboutSection
            }
            .formStyle(.grouped)
            .toggleStyle(AppSwitchStyle())
        }
        .frame(width: 540, height: height)
        .onAppear {
            setup.refresh()
            apiKey = Keychain.has(Keychain.openAIKey) ? Self.keyPlaceholder : ""
        }
    }

    /// Shown instead of the stored key, which is never read back into the UI.
    private static let keyPlaceholder = "••••••••••••••••••••"

    private var header: some View {
        HStack(spacing: 12) {
            AppGlyph(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.system(size: 20, weight: .bold, design: .rounded))
                Text(usesOpenAI
                     ? L("Ata %@ · transcribing with OpenAI", Updater.currentVersion)
                     : L("Ata %@ · everything runs on your Mac", Updater.currentVersion))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 8)
    }

    // MARK: Sections

    private var recordingSection: some View {
        Section("Recording") {
            Toggle("Detect meetings automatically", isOn: Binding(
                get: { autoDetect }, set: { store.setAutoDetect($0); autoDetect = $0 }))
            Picker("When a meeting is detected", selection: $autoStart) {
                Text("Ask me").tag(false)
                Text("Start recording").tag(true)
            }
            .disabled(!autoDetect)
            Toggle("Stop on its own when the meeting ends", isOn: $autoStop)
                .disabled(!autoDetect)
        }
    }

    private var menuBarSection: some View {
        Section("Menu bar") {
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

    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Engine", selection: Binding(
                get: { engine },
                set: { engine = $0; setup.setEngine(Engine(rawValue: $0) ?? .local) })) {
                Text("On this Mac (whisper.cpp)").tag(Engine.local.rawValue)
                Text("OpenAI API").tag(Engine.openAI.rawValue)
            }
            Text(usesOpenAI
                 ? L("Recorded audio is uploaded to OpenAI for transcription. Everything else stays on your Mac.")
                 : L("Nothing leaves your Mac. Runs on the GPU."))
                .font(.system(size: 11))
                .foregroundStyle(usesOpenAI ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !usesOpenAI {
                LocalModelRows()
            }

            TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
            Picker("Language", selection: $language) {
                Text("Automatic").tag("auto")
                Text("English").tag("en")
                Text("Português").tag("pt")
                Text("Español").tag("es")
                Text("Français").tag("fr")
                Text("Deutsch").tag("de")
                Text("Italiano").tag("it")
            }
            Toggle("Add an AI summary with decisions and action items", isOn: $summarize)
            if summarize {
                Text("Sends the finished transcript text to OpenAI, even when the audio is transcribed locally.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var openAISection: some View {
        Section("OpenAI") {
            HStack {
                SecureField("API key", text: $apiKey, prompt: Text("sk-…"))
                    .onSubmit { saveKey() }
                Button("Save") { saveKey() }
                    .disabled(apiKey.isEmpty || apiKey == Self.keyPlaceholder)
            }
            switch setup.keyCheck {
            case .checking:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").font(.system(size: 11)) }
            case .ok:
                Label("Key works", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 11))
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                HStack {
                    Text(setup.hasOpenAIKey ? L("Stored in your login keychain.") : L("No key stored yet."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if setup.hasOpenAIKey {
                        Button("Remove") {
                            apiKey = ""
                            setup.setOpenAIKey("")
                        }
                        .controlSize(.small)
                    }
                }
            }

            if usesOpenAI {
                Picker("Transcription model", selection: $openAIModel) {
                    ForEach(Pref.openAIModels, id: \.self) { Text($0).tag($0) }
                }
                if openAIModel != "whisper-1" {
                    Text("This model returns no timestamps, so the transcript has no per-line times and echo removal is skipped.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if summarize {
                Picker("Summary model", selection: $summaryModel) {
                    ForEach(Pref.summaryModels, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Keep the audio after transcribing", isOn: $keepAudio)
            Toggle("Compress kept audio to m4a", isOn: $compressAudio)
                .disabled(!keepAudio)
            Toggle("Also save the whole meeting as one MP3", isOn: Binding(
                get: { saveMP3 }, set: { saveMP3 = $0; if $0 { store.backfillMergedAudio() } }))
                .disabled(!keepAudio)
            Text(keepAudio
                 ? (compressAudio
                    ? L("Recordings are kept next to each transcript, about 10× smaller than the raw WAV.")
                    : L("Recordings are kept as WAV — roughly 115 MB per hour, per track."))
                 : L("Audio is deleted once the transcript is written. A failed transcription never deletes it."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Delete saved audio after", selection: Binding(
                get: { audioRetentionDays },
                set: { audioRetentionDays = $0; store.pruneOldAudio() })) {
                Text("Never").tag(0)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .disabled(!keepAudio)
            LabeledContent("Kept on disk") {
                Text(store.storageText)
            }
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
                if setup.ready {
                    Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Fix…") { WindowManager.shared.showOnboarding() }
                }
            }
            LabeledContent("Meetings folder") {
                Button("Open") { NSWorkspace.shared.open(Paths.meetingsDir) }
            }
        }
    }

    private var aboutSection: some View {
        Section {
            Text("Always tell the other participants that you are recording. Headphones help the transcript keep the speakers apart.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Link(destination: Updater.shared.releasesPage.deletingLastPathComponent()) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Spacer()
                CoffeeButton()
            }
            .font(.system(size: 11))
        }
    }

    private func saveKey() {
        guard apiKey != Self.keyPlaceholder else { return }
        setup.setOpenAIKey(apiKey)
        if !apiKey.isEmpty { apiKey = Self.keyPlaceholder }
    }
}

/// Model picker for the local engine, with download and clean-up.
struct LocalModelRows: View {
    @EnvironmentObject var setup: SetupModel
    /// Bumped after a change so the model state is read again.
    @State private var generation = 0

    private var model: LocalModel { _ = generation; return LocalModel.current }
    private var others: [LocalModel] { LocalModel.installed.filter { $0.id != model.id } }

    var body: some View {
        Picker("Model", selection: Binding(get: { model.id }, set: {
            Pref.d.set($0, forKey: Pref.localModel)
            generation += 1
            AppStore.shared.setupChanged()
        })) {
            ForEach(LocalModel.all) { m in
                Text(m.id == LocalModel.defaultID ? L("%@ — recommended", m.title) : m.title).tag(m.id)
            }
        }
        if LocalModel.betterAvailable, let better = LocalModel.find(LocalModel.defaultID) {
            LabeledContent {
                Button(L("Switch to %@", better.title)) {
                    Pref.d.set(better.id, forKey: Pref.localModel)
                    generation += 1
                    setup.refresh()
                    setup.downloadModels()
                }
            } label: {
                Text(L("%@ is more accurate, especially on calls and in Portuguese.", better.title))
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledContent {
            if model.isInstalled {
                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let p = setup.downloadProgress {
                HStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 90)
                    Text("\(Int(p * 100))%").font(.system(size: 10)).monospacedDigit()
                }
            } else {
                Button(L("Download %@", model.sizeText)) { setup.downloadModels() }
            }
        } label: {
            Text(model.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !others.isEmpty {
            LabeledContent {
                Button("Remove") {
                    for m in others { try? FileManager.default.removeItem(at: m.path) }
                    generation += 1
                    setup.refresh()
                }
            } label: {
                Text(L("Other models on disk: %@",
                       ByteCountFormatter.string(fromByteCount: others.reduce(0) { $0 + $1.bytes },
                                                 countStyle: .file)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .id(generation)
        }
        if let error = setup.downloadError {
            Text(error).font(.system(size: 11)).foregroundStyle(.red)
        }
    }
}

/// The recording icon on a strip of menu bar, so a change in Settings shows
/// before the next meeting does.
struct MenuIconPreview: View {
    let style: MenuIcon.Style
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !style.pulse)) { context in
            HStack(spacing: 4) {
                RecordingMenuIcon(style: style, date: context.date)
                if style.timer { Text(verbatim: "12:34").monospacedDigit() }
            }
            .font(.system(size: 13))
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.08)))
        }
        .accessibilityHidden(true)
    }
}

/// "Check for updates" / "Install" in one spot, driven by `Updater.state`.
struct UpdateControl: View {
    @StateObject private var updater = Updater.shared

    var body: some View {
        switch updater.state {
        case .idle:
            Button("Check now") { updater.check() }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").font(.system(size: 11)) }
        case .upToDate:
            Label(L("Ata %@ is the latest", Updater.currentVersion), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.system(size: 11))
        case .available(let version, _):
            Button(L("Install %@", version)) { updater.installUpdate() }
                .buttonStyle(.borderedProminent)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 80)
                Text("\(Int(p * 100))%").font(.system(size: 10)).monospacedDigit()
            }
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").font(.system(size: 11)) }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                Text(message).font(.system(size: 10)).foregroundStyle(.red)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Button("Try again") { updater.check() }.controlSize(.small)
            }
        }
    }
}

/// Buy-me-a-coffee link. The destination is in the Info.plist so a fork can
/// point it somewhere else without touching the code.
struct CoffeeButton: View {
    static var donateURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "AtaDonateURL") as? String
        return URL(string: configured ?? "") ?? URL(string: "https://buymeacoffee.com/mcpeixoto")!
    }

    var body: some View {
        Link(destination: Self.donateURL) {
            Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
        }
    }
}
