import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarLabel: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var live = LiveValues.shared
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

/// The menu's fixed width, and how many meetings it lists before "See all".
enum PopoverHome {
    static let width: CGFloat = 350
    static let recentLimit = 5
}

/// The line under "Record a meeting": a call Ata can already hear, otherwise the
/// next calendar meeting inside the next 12 hours. Further out is just noise
/// in a menu that is only open for a moment.
enum RecordCue: Equatable {
    case detected(app: String)
    case next(title: String, minutes: Int)
    case idle

    struct Upcoming: Equatable {
        var title: String
        var startsAt: Date
    }

    /// A stand-up later today, not tomorrow's first meeting.
    static let horizon: TimeInterval = 12 * 3600

    static func choose(detectedApp: String?, upcoming: [Upcoming], now: Date,
                       horizon: TimeInterval = horizon) -> RecordCue {
        if let app = detectedApp?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            return .detected(app: app)
        }
        let next = upcoming.filter { candidate in
            let delta = candidate.startsAt.timeIntervalSince(now)
            return delta <= horizon && -delta <= CalendarSchedule.grace
        }.min { $0.startsAt < $1.startsAt }
        guard let next else { return .idle }
        let delta = next.startsAt.timeIntervalSince(now)
        let minutes = delta <= 0 ? 0 : max(1, Int((delta / 60).rounded()))
        return .next(title: next.title, minutes: minutes)
    }

    var line: String {
        switch self {
        case .detected(let app):
            return L("%@ detected · tap to record", app)
        case .next(let title, 0):
            return L("Next: %@ now", title)
        case .next(let title, 1):
            return L("Next: %@ in 1 min", title)
        case .next(let title, let minutes):
            return L("Next: %@ in %d min", title, minutes)
        case .idle:
            return L("Your microphone and your Mac's audio. Works with any app.")
        }
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @State private var dropping = false
    @AppStorage(Pref.categoryFilter) private var categoryFilter = ""
    @AppStorage(Pref.summarize) private var summarize = true
    @AppStorage(Pref.appleBannerDismissed) private var appleBannerDismissed = false

    private var meetings: [Meeting] {
        Snapshots.omitMeetings ? [] : store.meetings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if let missing = setup.missingSummary { setupBanner(missing) }
            UpdateBanner(style: .banner)
            if let err = store.lastError { errorBanner(err) }
            recordCard
            chips
            if store.phase != .recording && store.phase != .stopping { recent }
            FreeQuotaFooter(layout: .inline)
            Divider().opacity(0.5)
            footer
        }
        .padding(Theme.Space.l)
        .frame(width: PopoverHome.width)
        .onAppear { setup.refresh(); store.reload(); store.writeOwedSummaries() }
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
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial))
                    .overlay {
                        Label("Drop audio to transcribe it", systemImage: "square.and.arrow.down")
                            .ataHeadline()
                    }
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .tint(Theme.accent)
    }

    /// Picks audio files to import, from the footer.
    private func chooseAudio() {
        if store.enforceFreeLimit() { return }
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
                Text("Ata").ataTitle()
                Text(statusLine).ataCaption().foregroundStyle(.secondary)
            }
            Spacer()
            Button { WindowManager.shared.showMain() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .ataFont(14, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Open in a window"))
            .accessibilityLabel(L("Open in a window"))
            Button { WindowManager.shared.showSettings() } label: {
                Image(systemName: "gearshape")
                    .ataFont(14, weight: .medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel(L("Settings"))
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
                return L("Transcribing on this Mac…")
            }
            if let app = store.detectedApp { return L("Meeting detected in %@", app) }
            return L("Ready to record")
        }
    }

    /// Only when turning it on would help, and only until you say no.
    private var showsAppleBanner: Bool {
        summarize && !appleBannerDismissed && AppleModel.state == .off && !Snapshots.rendering
    }

    @ViewBuilder private var chips: some View {
        HStack(spacing: Theme.Space.s) {
            NameVoicesBanner { WindowManager.shared.showMain(pane: .people) }
            UpdateBanner(style: .chip)
            if showsAppleBanner { appleChip }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appleChip: some View {
        BannerChip(systemImage: "sparkles",
                   title: Text("Turn on Apple Intelligence"),
                   help: L("It writes your summaries, on this Mac."),
                   action: { SetupModel.openAppleIntelligence() },
                   dismiss: { appleBannerDismissed = true },
                   dismissLabel: L("Don't show this again"))
    }

    private func setupBanner(_ text: String) -> some View {
        Banner(kind: .warning, mark: .symbol("wrench.and.screwdriver.fill"),
               title: Text("Finish setting up"),
               detail: Text(verbatim: text),
               action: { WindowManager.shared.showOnboarding() },
               showsChevron: true)
    }

    private func errorBanner(_ text: String) -> some View {
        Banner(kind: .danger, mark: .symbol("exclamationmark.triangle.fill"),
               title: Text(verbatim: text),
               dismiss: { store.lastError = nil },
               dismissLabel: L("Dismiss"))
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

    /// The calendar is the user's. Snapshots must not read it, or a README image
    /// could show a real meeting title.
    private var cue: RecordCue {
        let now = Date()
        guard !Snapshots.rendering else {
            return RecordCue.choose(detectedApp: store.detectedApp, upcoming: [], now: now)
        }
        let lead = TimeInterval(max(0, Pref.d.integer(forKey: Pref.calendarLeadMinutes))) * 60
        let peopleOnly = Pref.d.bool(forKey: Pref.calendarPeopleOnly)
        let upcoming = CalendarSchedule.occurrences(
            in: CalendarStore.shared.upcoming(now: now), now: now, lead: lead, peopleOnly: peopleOnly
        ).map { RecordCue.Upcoming(title: $0.event.title, startsAt: $0.event.startsAt) }
        return RecordCue.choose(detectedApp: store.detectedApp, upcoming: upcoming, now: now)
    }

    private var idleContent: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            HeroRecordButton(size: 56, state: store.phase == .starting ? .busy : .idle) {
                store.toggleRecording()
            }
            .disabled(store.phase == .starting)
            .opacity(store.phase == .starting ? 0.6 : 1)
            .accessibilityLabel(L("Record a meeting"))
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(store.phase == .starting ? "Getting ready…" : "Record a meeting")
                        .ataHeadline()
                    Spacer(minLength: Theme.Space.s)
                    Text(verbatim: "⌘R")
                        .ataCaption()
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: cue.line)
                    .ataCaption()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(cueHelp)
        .background(
            Button("") { store.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    /// The old sentence stays available on hover when a call is already detected.
    private var cueHelp: String {
        switch cue {
        case .detected: return L("Hit record to capture and transcribe it.")
        default: return L("Start recording (⌘R)")
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                SectionLabel(L("RECENT"))
                Spacer(minLength: Theme.Space.s)
                if !meetings.isEmpty { categoryMenu }
                Button("See all") { WindowManager.shared.showMain(pane: .meetings) }
                    .buttonStyle(.plain)
                    .ataCaption()
                    .foregroundStyle(Theme.accent)
            }
            if meetings.isEmpty {
                FirstMeetingsCard()
            } else {
                let shown = meetings.filter { MeetingCategory.matches($0, filter: categoryFilter) }
                VStack(spacing: 2) {
                    ForEach(shown.prefix(PopoverHome.recentLimit)) { m in
                        MeetingRow(meeting: m)
                    }
                    if shown.isEmpty {
                        EmptyState(icon: "tag", title: L("No meetings here yet"), message: "")
                            .padding(.vertical, Theme.Space.s)
                    }
                }
            }
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button("All") { categoryFilter = "" }
            ForEach(MeetingCategory.allCases) { category in
                Button { categoryFilter = category.rawValue } label: {
                    Text(verbatim: category.name)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(verbatim: MeetingCategory(rawValue: categoryFilter)?.name ?? L("All"))
                Image(systemName: "chevron.down")
                    .ataFont(9, weight: .semibold)
            }
            .ataCaption()
            .foregroundStyle(Theme.accent)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Footer

    /// Asks only when quitting would interrupt something.
    private func quit() {
        if let warning = QuitWarning.needed(recording: store.phase == .recording,
                                            transcribing: store.transcribingID != nil) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = warning.title
            alert.informativeText = warning.detail
            alert.addButton(withTitle: L("Quit Ata"))
            alert.addButton(withTitle: L("Keep running"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    private var footer: some View {
        // One line at the menu's width. "Importar áudio…" wraps if a button is
        // allowed to shrink, and the meeting window is simply wider.
        HStack(spacing: 0) {
            GhostButton(title: L("Folder"), systemImage: "folder") {
                NSWorkspace.shared.open(Paths.meetingsDir)
            }
            GhostButton(title: L("Import audio…"), systemImage: "square.and.arrow.down") { chooseAudio() }
                .help(L("Transcribe audio recorded elsewhere. You can also drop files here."))
            Spacer()
            GhostButton(title: L("Quit Ata"), systemImage: "power") { quit() }
            .help(L("Stops Ata, including the menu bar icon. Closing a window leaves Ata running there."))
        }
    }
}

/// Card contents while recording.
private struct RecordingContent: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var live = LiveValues.shared
    @State private var confirmDiscard = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    PulsingDot(color: Theme.recordingSolid)
                    Text(store.phase == .stopping ? L("WRAPPING UP") : L("RECORDING"))
                        .ataLabel()
                        .foregroundStyle(Theme.recordingSolid)
                }
                Spacer()
                Text(store.elapsedText)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }

            Grid(horizontalSpacing: Theme.Space.s, verticalSpacing: Theme.Space.s) {
                GridRow {
                    meterIcon("mic.fill", Theme.meTint)
                    meterLabel(Pref.myNameOrDefault)
                    LevelMeter(level: store.micLevel, tint: Theme.meTint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    meterIcon("speaker.wave.2.fill", Theme.othersTint)
                    meterLabel(L("Others"))
                    LevelMeter(level: store.systemLevel, tint: Theme.othersTint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let w = store.warning {
                HStack(spacing: 6) {
                    // Only while Ata is trying again. A full disk or a silent side
                    // is not something a spinner can fix.
                    if Recorder.warningIsRetry(w) {
                        ProgressView().controlSize(.mini)
                    }
                    Text(w).ataCaption().foregroundStyle(Theme.warning).lineLimit(2)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.stopRecording()
                } label: {
                    Label("Stop and transcribe", systemImage: "stop.fill")
                        .ataHeadline()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Theme.record))
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
                    .ataCallout()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(store.bookmarkCount > 0 ? Theme.moment : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("b", modifiers: .command)
                .disabled(store.phase == .stopping)
                .help(L("Mark this moment (⌘B)"))
                .accessibilityLabel(L("Mark this moment"))

                Button {
                    if confirmDiscard {
                        store.discardRecording()
                    } else {
                        confirmDiscard = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmDiscard = false }
                    }
                } label: {
                    Text(confirmDiscard ? L("Delete?") : L("Discard"))
                        .ataCallout()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .fill(confirmDiscard ? Color.red.opacity(0.15) : Color.primary.opacity(0.06)))
                        .foregroundStyle(confirmDiscard ? Color.red : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.phase == .stopping)
            }
        }
    }

    private func meterIcon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 10))
            .foregroundStyle(tint)
            .frame(width: 14)
    }

    private func meterLabel(_ label: String) -> some View {
        Text(label)
            .ataCaption()
            .lineLimit(1)
            .gridColumnAlignment(.leading)
    }
}

/// One meeting in the recent list.
struct MeetingRow: View {
    enum Activation { case singleTap, doubleClick }

    @EnvironmentObject var store: AppStore
    let meeting: Meeting
    var activation: Activation = .singleTap
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            MeetingRowContent(meeting: meeting) {
                if isTranscribing {
                    TranscribeStatus().ataCaption()
                } else {
                    Text(verbatim: detail).ataCaption().foregroundStyle(detailColor).lineLimit(1)
                }
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
        .modifier(MeetingOpen(activation: activation, action: { open() }))
        .contextMenu { menu }
    }

    private var isTranscribing: Bool { store.transcribingID == meeting.id }

    private var detail: String {
        if meeting.isPlaceholder { return L("Downloading from iCloud…") }
        switch meeting.status {
        case .failed: return meeting.error ?? L("Failed")
        case .pending: return L("Queued") + " · \(meeting.subtitle)"
        case .recording: return L("Recording…")
        case .done where store.summarizingID == meeting.id:
            return TranscribeStage.summary.label + " · \(meeting.subtitle)"
        default: return meeting.subtitle
        }
    }

    private var detailColor: Color { meeting.status == .failed ? Theme.danger : .secondary }

    @ViewBuilder
    private var trailing: some View {
        if isTranscribing {
            RowProgress()
        } else if meeting.status == .failed && meeting.hasAudio {
            Button("Try again") { store.retry(meeting) }
                .controlSize(.small)
                .disabled(!store.canRetry(meeting))
                .savingAudioHelp(store.isSavingAudio(meeting.id))
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
            .disabled(!store.canDelete(meeting))
            .savingAudioHelp(store.isSavingAudio(meeting.id))
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


/// One meeting, opened with a single tap in the menu and a double-click in the library.
private struct MeetingOpen: ViewModifier {
    var activation: MeetingRow.Activation
    var action: () -> Void

    func body(content: Content) -> some View {
        switch activation {
        case .singleTap:
            content.onTapGesture(perform: action)
        case .doubleClick:
            content
                .onTapGesture(count: 2, perform: action)
                .accessibilityAction(named: Text("Open meeting"), action)
        }
    }
}

/// What an empty library says, in the menu and in the window. Three steps, not a blank.
struct FirstMeetingsCard: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                step(1, Text("Start a call"))
                step(2, Text("Ata offers to record"))
                step(3, Text("Notes appear here"))
            }
        }
    }

    private func step(_ number: Int, _ title: Text) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(verbatim: "\(number)")
                .ataCaption()
                .foregroundStyle(Theme.accentInk)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent))
            title.ataCallout()
        }
    }
}

/// Offers the new version at the top of the menu once a check has found one.
/// A version that is ready is a chip; downloading, installing and a failure
/// stay banners, because a chip has no room for progress or an error.
struct UpdateBanner: View {
    enum Style { case banner, chip }
    var style: Style = .banner
    @StateObject private var updater = Updater.shared

    var body: some View {
        switch style {
        case .chip:
            if case .available(let version, _) = updater.state {
                BannerChip(systemImage: "arrow.down.circle.fill",
                           title: Text("Update"),
                           help: L("Ata %@ is available", version) + "\n" + L("Click to download and restart."),
                           action: { updater.installUpdate() })
            }
        case .banner:
            banner
        }
    }

    @ViewBuilder private var banner: some View {
        switch updater.state {
        case .downloading(let p):
            Banner(kind: .info, mark: .progress(p),
                   title: Text(verbatim: L("Downloading the update… %d%%", Int(p * 100))))
        case .installing:
            Banner(kind: .info, mark: .progress(nil),
                   title: Text("Installing the update…"))
        case .failed(let message):
            Banner(kind: .danger, mark: .symbol("exclamationmark.triangle.fill"),
                   title: Text(verbatim: message),
                   dismiss: { updater.dismiss() },
                   dismissLabel: L("Dismiss"))
        default:
            EmptyView()
        }
    }
}


/// "2 voices to name" — shown until the user has named the voices Ata keeps hearing.
struct NameVoicesBanner: View {
    @StateObject private var people = PeopleModel.shared
    let open: () -> Void

    var body: some View {
        let count = people.enabled ? people.worthAsking.count : 0
        if count > 0, !Snapshots.omitMeetings {
            BannerChip(systemImage: "person.crop.circle.badge.questionmark",
                       title: Text(verbatim: count == 1 ? L("1 voice to name") : L("%d voices to name", count)),
                       help: L("Name them once; every transcript uses the name."),
                       action: open)
                .onAppear { people.reload() }
        }
    }
}

/// The transcribing row's bar. Its own view, so a progress tick redraws the
/// bar and not every row of the list.
private struct RowProgress: View {
    @ObservedObject private var live = LiveValues.shared

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: live.transcribeProgress)
                .progressViewStyle(.linear)
                .frame(width: 60)
                .animation(.easeOut(duration: 0.4), value: live.transcribeProgress)
            Text("\(Int(live.transcribeProgress * 100))%")
                .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}

/// What the transcription is doing now and how long it has left, under the
/// meeting's title: an hour of audio takes a while, and a bar alone doesn't
/// say when it will be done. Redrawn every few seconds as the time runs down.
struct TranscribeStatus: View {
    @ObservedObject private var live = LiveValues.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(line(at: context.date))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
        }
    }

    private func line(at now: Date) -> String {
        let stage = (live.stage ?? .preparing).label
        guard let left = live.remaining(at: now) else { return stage }
        return stage + " · " + TranscribeETA.text(left)
    }
}
