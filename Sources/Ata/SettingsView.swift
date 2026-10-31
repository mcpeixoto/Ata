import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @StateObject private var updater = Updater.shared
    @StateObject private var cloud = CloudSync.shared

    @AppStorage(Pref.autoDetect) private var autoDetect = true
    @AppStorage(Pref.autoStart) private var autoStart = false
    @AppStorage(Pref.autoStop) private var autoStop = true
    @AppStorage(Pref.keepAudio) private var keepAudio = true
    @AppStorage(Pref.compressAudio) private var compressAudio = true
    @AppStorage(Pref.saveMP3) private var saveMP3 = true
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.summarize) private var summarize = true
    @AppStorage(Pref.cancelEcho) private var cancelEcho = true
    @AppStorage(Pref.summaryTemplate) private var summaryTemplate = SummaryTemplate.standard.rawValue
    @AppStorage(Pref.dictionary) private var dictionary = ""
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    @AppStorage(Pref.audioRetentionDays) private var audioRetentionDays = 0
    @AppStorage(Pref.calendarPrompt) private var calendarPrompt = false
    @AppStorage(Pref.calendarLeadMinutes) private var calendarLeadMinutes = 1
    @AppStorage(Pref.calendarPeopleOnly) private var calendarPeopleOnly = true
    @State private var recordShortcut: Shortcut? = Hotkey.current
    @AppStorage(Pref.defaultCategory) private var defaultCategory = ""
    @State private var calendarCategories = MeetingCategory.calendarMap
    @AppStorage(Pref.dockIcon) private var dockIcon = false
    @AppStorage(Pref.menuBarIcon) private var menuBarIcon = true
    @AppStorage(Pref.menuIconSymbol) private var menuIconSymbol = MenuIcon.Symbol.dot.rawValue
    @AppStorage(Pref.menuIconTint) private var menuIconTint = MenuIcon.Tint.monochrome.rawValue
    @AppStorage(Pref.menuIconTimer) private var menuIconTimer = true
    @AppStorage(Pref.menuIconPulse) private var menuIconPulse = false
    @AppStorage(Pref.menuIconProgress) private var menuIconProgress = true

    /// The window's height. Only the snapshot renderer asks for a taller one.
    var height: CGFloat = 660

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                recordingSection
                calendarSection
                categorySection
                presenceSection
                menuBarSection
                transcriptionSection
                audioSection
                iCloudSection
                systemSection
                aboutSection
            }
            .formStyle(.grouped)
            .toggleStyle(AppSwitchStyle())
        }
        .frame(width: 540, height: height)
        .onAppear {
            setup.refresh()
            cloud.recheck()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppGlyph(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Settings").font(.system(size: 20, weight: .bold, design: .rounded))
                Text(L("Ata %@ · everything runs on your Mac", Updater.currentVersion))
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

    private var calendarSection: some View {
        Section("Calendar") {
            Toggle("Offer to record meetings on my calendar", isOn: Binding(
                get: { calendarPrompt },
                set: { on in
                    calendarPrompt = on
                    if on, !setup.calendar { setup.requestCalendar() } else { store.calendarChanged() }
                }))
            if calendarPrompt {
                Picker("How long before", selection: $calendarLeadMinutes) {
                    ForEach([1, 2, 5, 10, 15], id: \.self) { minutes in
                        Text(minutes == 1 ? L("A minute") : L("%d minutes", minutes)).tag(minutes)
                    }
                }
                .onChange(of: calendarLeadMinutes) { _, _ in store.calendarChanged() }
                Toggle("Only events with other people invited", isOn: $calendarPeopleOnly)
                    .onChange(of: calendarPeopleOnly) { _, _ in store.calendarChanged() }
                if !setup.calendar {
                    LabeledContent(L("Access")) {
                        Button(L("Allow")) { setup.requestCalendar() }
                    }
                }
            }
            Text(calendarFootnote)
                .font(.system(size: 11))
                .foregroundStyle(calendarPrompt && !setup.calendar ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var categorySection: some View {
        Section("Work and personal") {
            Picker("New meetings", selection: $defaultCategory) {
                Text("No category").tag("")
                ForEach(MeetingCategory.allCases) { c in Text(c.name).tag(c.rawValue) }
            }
            if setup.calendar {
                ForEach(CalendarStore.shared.calendars(), id: \.id) { calendar in
                    Picker(calendar.title, selection: Binding(
                        get: { calendarCategories[calendar.id] ?? "" },
                        set: { value in
                            calendarCategories[calendar.id] = value.isEmpty ? nil : value
                            MeetingCategory.calendarMap = calendarCategories
                        })) {
                        Text("No category").tag("")
                        ForEach(MeetingCategory.allCases) { c in Text(c.name).tag(c.rawValue) }
                    }
                }
            }
            Text(setup.calendar
                 ? L("A meeting from one of these calendars gets its category. Otherwise Ata goes by the app: Zoom, Teams or Slack is work, FaceTime or WhatsApp is personal. You can change it in the meeting.")
                 : L("Ata goes by the app: Zoom, Teams or Slack is work, FaceTime or WhatsApp is personal. Allow the calendar above to choose per calendar. You can change it in the meeting."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What this will actually do, given everything else that is switched on. A
    /// setting that quietly does nothing is worse than one that says why.
    private var calendarFootnote: String {
        if calendarPrompt, !setup.calendar, setup.calendarAskWasSilent {
            return L("macOS did not ask. Turn Ata on under Calendars in System Settings → Privacy & Security.")
        }
        if calendarPrompt, !setup.calendar {
            return setup.calendarDenied
                ? L("Ata cannot read your calendar. Turn it on under Calendars in System Settings → Privacy & Security.")
                : L("Ata needs permission to read your calendar.")
        }
        if calendarPrompt, !setup.notifications {
            return L("Turn on notifications for Ata and the prompt arrives there. Until then the next meeting shows in Ata's window.")
        }
        if calendarPrompt, autoStart {
            return L("Recording starts on its own when the meeting does, because \"When a meeting is detected\" is set to start recording.")
        }
        if calendarPrompt {
            return L("A notification before the meeting, with a Record button. The recording is filed under the event's title, and the people invited are what Ata offers when it asks whose voice it heard.")
        }
        return L("Ata reads the calendars already in Calendar.app, your Google account included. Nothing leaves your Mac, and Ata never writes to a calendar.")
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
            Text("Ata lives in the menu bar, not the Dock. Closing a window leaves it running there. Quit Ata from the menu bar icon when you want it to stop. The Dock is only for a menu bar that has no room left: macOS hides the icons that don't fit, and an app cannot choose where its icon sits.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Record from anywhere") {
                ShortcutField(shortcut: $recordShortcut) { new in
                    Hotkey.set(new) { AppStore.shared.toggleRecording() }
                }
                .frame(width: 140, height: 22)
                // An NSView has no text baseline, so LabeledContent lined the
                // field's bottom edge up with the label's baseline and the field
                // sat below it. Give it one, a little under its middle, where its
                // own 11–12 pt text sits.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            if recordShortcut != nil, !Hotkey.isRegistered {
                Text("Another app already uses that combination. Try a different one.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            } else {
                Text("Starts or stops recording without going near the icon, from whatever app you are in.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            LocalModelRows()
            Text("Whisper Large is the model Ata uses. It runs on this Mac, and nothing you record is uploaded.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
            Picker("Language", selection: $language) {
                Text("Automatic").tag("auto")
                ForEach(Pref.languageChoices, id: \.code) { choice in
                    Text(choice.name).tag(choice.code)
                }
            }
            TextField("Names and words to spell right", text: $dictionary, prompt: Text("Copilot, Attio, Bernardo"))
            Text("People you have named are included on their own. In a summary, they are spelled as written here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Remove the others' voices from your microphone", isOn: $cancelEcho)
            Text("For calls without headphones: Ata takes what your Mac played out of your microphone before transcribing. The recording itself is not changed.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Add an AI summary with decisions and action items", isOn: $summarize)
            if summarize {
                Picker("Note template", selection: $summaryTemplate) {
                    ForEach(SummaryTemplate.allCases) { template in
                        Text(template.title).tag(template.rawValue)
                    }
                }
                summaryFootnote
            }
        }
    }

    @ViewBuilder
    private var summaryFootnote: some View {
        if AppleModel.isAvailable {
            Text("Written on this Mac by Apple Intelligence. Nothing leaves it.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if let reason = AppleModel.unavailableReason {
                Text(reason)
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Turn on Apple Intelligence") { SetupModel.openAppleIntelligence() }
        }
    }

    /// The one line under the summary engine picker.
    enum SummaryNote: Equatable {
        /// OpenAI writes it: say what is uploaded.
        case sendsToOpenAI
        /// Apple Intelligence was chosen but can't write it, and why.
        case appleUnavailable(String)
        /// Apple Intelligence writes it; with "auto" and a key, OpenAI is the fallback.
        case onThisMac(fallsBackToOpenAI: Bool)
    }

    /// Decided from what the picker shows, not from what is stored: "auto" on a
    /// Mac without Apple Intelligence shows OpenAI, and a line telling you to turn
    /// Apple Intelligence on under "OpenAI" read as a contradiction.
    static func summaryNote(engine stored: String, appleAvailable: Bool,
                            appleUnavailableReason: String?, hasOpenAIKey: Bool) -> SummaryNote {
        let chosen = SummaryEngine(rawValue: stored)
        let shown = chosen ?? (appleAvailable ? .apple : .openAI)
        if shown == .openAI { return .sendsToOpenAI }
        if let reason = appleUnavailableReason { return .appleUnavailable(reason) }
        return .onThisMac(fallsBackToOpenAI: chosen == nil && hasOpenAIKey)
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

    private var iCloudSection: some View {
        Section("iCloud") {
            Toggle("Keep meetings in iCloud", isOn: Binding(
                get: { (cloud.isOn || cloud.copying) && !cloud.copyingOut },
                set: { on in
                    if on { cloud.turnOn() } else { cloud.turnOff() }
                }))
                .disabled(!cloud.isOn && !cloud.copying && cloud.status != .available)
            if cloud.copying && cloud.total > 0 {
                ProgressView(value: Double(cloud.copied), total: Double(cloud.total)) {
                    Text(cloud.copyingOut
                         ? L("Copying your meetings from iCloud… %d of %d", cloud.copied, cloud.total)
                         : L("Copying your meetings into iCloud… %d of %d", cloud.copied, cloud.total))
                        .font(.system(size: 11))
                }
            }
            Text(iCloudFootnote)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let originals = cloud.originals {
                LabeledContent("Originals on this Mac") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([originals]) }
                }
                Text("They were copied into iCloud and checked. Remove them when you no longer need them.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var iCloudFootnote: String {
        if let problem = cloud.problem { return problem }
        if cloud.copyingOut {
            return L("Ata keeps using iCloud until every meeting is copied to this Mac and checked. Nothing is removed from iCloud.")
        }
        if cloud.copying {
            return L("The originals stay where they are. Ata moves to the copy once every meeting is in iCloud and checked.")
        }
        if cloud.isOn {
            return L("Your meetings and voices are in iCloud Drive, and show up in Ata on your iPhone. Turned off, Ata goes back to the meetings on this Mac; what's in iCloud stays there.")
        }
        switch cloud.status {
        case .checking:
            return L("Checking iCloud…")
        case .available:
            return L("Copies your meetings and voices into iCloud Drive, so Ata on your iPhone shows them too. The originals stay on this Mac.")
        case .signedOut:
            return L("Sign in to iCloud and turn on iCloud Drive in System Settings to use this.")
        case .notOnThisMac:
            return L("Turn on “Keep meetings in iCloud” in Ata on your iPhone first. This Mac then uses the same folder.")
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

/// Apple's speech model for each language Ata may transcribe: there, to
/// download, or not offered. macOS downloads it and shares it between apps.
struct AppleSpeechRows: View {
    let language: String
    @StateObject private var models = AppleSpeechModels()

    var body: some View {
        ForEach(models.rows) { row in
            LabeledContent {
                switch row.state {
                case .checking:
                    ProgressView().controlSize(.small)
                case .installed:
                    Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .missing:
                    Button("Download speech model") { models.download(row.code) }
                case .downloading(let p):
                    HStack(spacing: 6) {
                        ProgressView(value: p).frame(width: 90)
                        Text("\(Int(p * 100))%").font(.system(size: 10)).monospacedDigit()
                    }
                case .unsupported:
                    Text("Not available yet").font(.system(size: 11)).foregroundStyle(.orange)
                case .failed(let message):
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(message).font(.system(size: 10)).foregroundStyle(.red)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { models.download(row.code) }.controlSize(.small)
                    }
                }
            } label: {
                Text(L("Speech model: %@", row.name)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .onAppear { models.refresh(language: language) }
        .onChange(of: language) { _, new in models.refresh(language: new) }
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
            // The button stays. Replacing it with the answer meant that once Ata
            // had told you it was the latest, it went on saying so for the rest of
            // the session — there was nothing left to click, and the only way to
            // ask again was to quit the app.
            HStack(spacing: 8) {
                Label(L("Ata %@ is the latest", Updater.currentVersion), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 11))
                Button("Check again") { updater.check() }.controlSize(.small)
            }
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
