import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarLabel: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(Pref.menuIconSymbol) private var symbol = MenuIcon.Symbol.dot.rawValue
    @AppStorage(Pref.menuIconTint) private var tint = MenuIcon.Tint.monochrome.rawValue
    @AppStorage(Pref.menuIconTimer) private var timer = true
    @AppStorage(Pref.menuIconPulse) private var pulse = false
    @AppStorage(Pref.menuIconProgress) private var progress = true

    var body: some View {
        switch store.phase {
        case .recording, .stopping:
            HStack(spacing: 4) {
                RecordingMenuIcon(style: MenuIcon.Style(symbol: symbol, tint: tint, timer: timer, pulse: pulse),
                                  date: store.now)
                if timer { Text(store.elapsedText).monospacedDigit() }
            }
        case .starting:
            Image(systemName: "record.circle")
        case .idle:
            if store.transcribingID != nil {
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                    if progress { Text("\(Int(store.transcribeProgress * 100))%").monospacedDigit() }
                }
            } else if store.detectedApp != nil {
                Image(systemName: "waveform.circle.fill")
            } else {
                Image(systemName: "waveform")
            }
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel

    enum Tab: Hashable { case record, insights, people }
    @State private var tab: Tab
    @State private var dropping = false

    init(tab: Tab = .record) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let missing = setup.missingSummary { setupBanner(missing) }
            UpdateBanner()
            if tab != .people { NameVoicesBanner { tab = .people } }
            if let err = store.lastError { errorBanner(err) }
            Picker("", selection: $tab) {
                Text("Record").tag(Tab.record)
                Text("Insights").tag(Tab.insights)
                Text("People").tag(Tab.people)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch tab {
            case .record:
                recordCard
                if !store.meetings.isEmpty { recent }
            case .insights:
                InsightsView()
            case .people:
                PeopleView()
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(14)
        .frame(width: 350)
        .onAppear { setup.refresh(); store.reload() }
        // Audio files dropped on the menu become meetings.
        .dropDestination(for: URL.self) { urls, _ in
            MainActor.assumeIsolated {
                store.importAudio(urls)
                return urls.contains(where: AudioImport.accepts)
            }
        } isTargeted: { targeted in
            MainActor.assumeIsolated { dropping = targeted }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial))
                    .overlay {
                        Label("Drop audio to transcribe it", systemImage: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Picks audio files to import, from the footer.
    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AudioImport.types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Choose recordings to transcribe. The files stay where they are.")
        panel.prompt = L("Import")
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        store.importAudio(panel.urls)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ata").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { WindowManager.shared.showSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
    }

    private var statusLine: String {
        switch store.phase {
        case .starting: return L("Getting ready…")
        case .recording: return L("Recording") + (store.currentApp.map { " · \($0)" } ?? "")
        case .stopping: return L("Wrapping up…")
        case .idle:
            if store.importing > 0 { return L("Importing audio…") }
            if store.transcribingID != nil {
                return Engine.current.isLocal ? L("Transcribing on this Mac…") : L("Transcribing with OpenAI…")
            }
            if let app = store.detectedApp { return L("Meeting detected in %@", app) }
            return L("Ready to record")
        }
    }

    private func setupBanner(_ text: String) -> some View {
        Button { WindowManager.shared.showOnboarding() } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Finish setting up").font(.system(size: 12, weight: .semibold))
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { store.lastError = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.10)))
    }

    // MARK: Recording

    @ViewBuilder
    private var recordCard: some View {
        Card {
            switch store.phase {
            case .idle, .starting:
                idleContent
            case .recording, .stopping:
                RecordingContent()
            }
        }
    }

    private var idleContent: some View {
        HStack(spacing: 14) {
            RecordButton { store.toggleRecording() }
                .disabled(store.phase == .starting)
                .opacity(store.phase == .starting ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 4) {
                if let app = store.detectedApp {
                    HStack(spacing: 6) {
                        PulsingDot(color: .green)
                        Text(L("Meeting in %@", app)).font(.system(size: 13, weight: .semibold))
                    }
                    Text("Hit record to capture and transcribe it.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(store.phase == .starting ? L("Getting ready…") : L("Record a meeting"))
                        .font(.system(size: 14, weight: .semibold))
                    Text("Your microphone and your Mac's audio. Works with any app.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .background(
            Button("") { store.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
        )
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECENT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 2) {
                ForEach(store.meetings.prefix(6)) { m in
                    MeetingRow(meeting: m)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            GhostButton(title: L("Folder"), systemImage: "folder") {
                NSWorkspace.shared.open(Paths.meetingsDir)
            }
            GhostButton(title: L("Import audio…"), systemImage: "square.and.arrow.down") { chooseAudio() }
                .help(L("Transcribe audio recorded elsewhere. You can also drop files here."))
            Spacer()
            Link(destination: CoffeeButton.donateURL) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Buy me a coffee"))
            .padding(.horizontal, 8)
            GhostButton(title: L("Quit"), systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
    }
}

/// Card contents while recording.
private struct RecordingContent: View {
    @EnvironmentObject var store: AppStore
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    PulsingDot()
                    Text(store.phase == .stopping ? L("WRAPPING UP") : L("RECORDING"))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text(store.elapsedText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            VStack(spacing: 8) {
                meter(Pref.myNameOrDefault, icon: "mic.fill",
                      level: store.micLevel, tint: Theme.meTint)
                meter(L("Others"), icon: "speaker.wave.2.fill", level: store.systemLevel, tint: Theme.othersTint)
            }

            if let w = store.warning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(w).font(.system(size: 11)).foregroundStyle(.orange)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.stopRecording()
                } label: {
                    Label("Stop and transcribe", systemImage: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.record))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(store.phase == .stopping)

                Button {
                    store.addBookmark()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: store.bookmarkCount > 0 ? "bookmark.fill" : "bookmark")
                        if store.bookmarkCount > 0 {
                            Text(verbatim: "\(store.bookmarkCount)").monospacedDigit()
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(store.bookmarkCount > 0 ? Color.orange : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("b", modifiers: .command)
                .disabled(store.phase == .stopping)
                .help(L("Mark this moment (⌘B)"))

                Button {
                    if confirmDiscard {
                        store.discardRecording()
                    } else {
                        confirmDiscard = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDiscard = false }
                    }
                } label: {
                    Text(confirmDiscard ? L("Delete?") : L("Discard"))
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(confirmDiscard ? Color.red.opacity(0.15) : Color.primary.opacity(0.06)))
                        .foregroundStyle(confirmDiscard ? Color.red : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.phase == .stopping)
            }
        }
    }

    private func meter(_ label: String, icon: String, level: Float, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint).frame(width: 14)
            Text(label).font(.system(size: 11, weight: .medium)).frame(width: 56, alignment: .leading)
                .lineLimit(1)
            LevelMeter(level: level, tint: tint)
        }
    }
}

/// One meeting in the recent list.
struct MeetingRow: View {
    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(detailColor).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open() }
        .contextMenu { menu }
    }

    private var isTranscribing: Bool { store.transcribingID == meeting.id }

    private var detail: String {
        switch meeting.status {
        case .failed: return meeting.error ?? L("Failed")
        case .pending: return L("Queued") + " · \(meeting.subtitle)"
        case .recording: return L("Recording…")
        default: return meeting.subtitle
        }
    }

    private var detailColor: Color { meeting.status == .failed ? .red : .secondary }

    private var icon: some View {
        let (symbol, color): (String, Color) = {
            switch meeting.status {
            case .done: return ("doc.text.fill", .accentColor)
            case .failed: return ("exclamationmark.triangle.fill", .red)
            case .recording: return ("record.circle.fill", .red)
            case .pending, .transcribing: return ("hourglass", .orange)
            }
        }()
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.opacity(0.14))
            .frame(width: 28, height: 28)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color))
    }

    @ViewBuilder
    private var trailing: some View {
        if isTranscribing {
            HStack(spacing: 6) {
                ProgressView(value: store.transcribeProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 60)
                Text("\(Int(store.transcribeProgress * 100))%")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        } else if meeting.status == .failed && meeting.hasAudio {
            Button("Try again") { store.retry(meeting) }
                .controlSize(.small)
        } else if meeting.status != .recording && hover {
            Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var menu: some View {
        if meeting.status != .recording {
            Button("Open meeting") { open() }
            if meeting.hasAudio || meeting.hasMergedAudio {
                Button("Play") { WindowManager.shared.showMeeting(meeting.id, play: true) }
            }
        }
        if meeting.status == .done {
            Button("Open transcript") {
                if let transcript = meeting.existingTranscriptURL { NSWorkspace.shared.open(transcript) }
            }
            Button("Copy text") { copy() }
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.dir]) }
        TranscribeAgainMenu(meeting: meeting)
        if FileManager.default.fileExists(atPath: meeting.versionsDir.path) {
            Button("Show earlier versions") { NSWorkspace.shared.open(meeting.versionsDir) }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(meeting) }
            .disabled(meeting.status == .recording || isTranscribing)
    }

    private func open() {
        if meeting.status == .recording {
            NSWorkspace.shared.activateFileViewerSelecting([meeting.dir])
        } else {
            WindowManager.shared.showMeeting(meeting.id)
        }
    }

    private func copy() {
        guard let url = meeting.existingTranscriptURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}


/// Offers the new version at the top of the menu once a check has found one.
struct UpdateBanner: View {
    @StateObject private var updater = Updater.shared

    var body: some View {
        switch updater.state {
        case .available(let version, _):
            row {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Ata %@ is available", version)).font(.system(size: 12, weight: .semibold))
                    Text("Click to download and restart.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .onTapGesture { updater.installUpdate() }
        case .downloading(let p):
            row {
                ProgressView(value: p).frame(width: 90)
                Text(L("Downloading the update… %d%%", Int(p * 100)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        case .installing:
            row {
                ProgressView().controlSize(.small)
                Text("Installing the update…").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
        case .failed(let message):
            row {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button { updater.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.12)))
            .contentShape(Rectangle())
    }
}


/// "2 voices to name" — shown until the user has named the voices Ata keeps hearing.
struct NameVoicesBanner: View {
    @StateObject private var people = PeopleModel.shared
    let open: () -> Void

    var body: some View {
        let count = people.enabled ? people.worthAsking.count : 0
        if count > 0 {
            Button(action: open) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(count == 1 ? L("1 voice to name") : L("%d voices to name", count))
                            .font(.system(size: 12, weight: .semibold))
                        Text("Name them once; every transcript uses the name.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onAppear { people.reload() }
        }
    }
}
