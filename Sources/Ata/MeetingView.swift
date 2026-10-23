import AppKit
import SwiftUI

/// One meeting in its own window: listen to it, read the notes and the
/// transcript, and name the people in it.
struct MeetingView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var model: MeetingModel
    @StateObject private var people = PeopleModel.shared

    enum Tab: Hashable { case notes, transcript, people }
    @State private var tab: Tab
    @State private var confirmDelete = false

    /// The window's height. Only the snapshot renderer asks for a fixed one.
    var height: CGFloat? = nil

    init(model: MeetingModel, tab: Tab? = nil, height: CGFloat? = nil) {
        _model = StateObject(wrappedValue: model)
        let hasNotes = model.summary != nil || !model.notes.isEmpty
        _tab = State(initialValue: tab ?? (hasNotes ? .notes : .transcript))
        self.height = height
    }

    var body: some View {
        Group {
            if let meeting = model.meeting {
                content(meeting)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "trash").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("This meeting was deleted.").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .frame(height: height)
        .onReceive(store.$meetings) { _ in model.reload() }
        .onReceive(people.$voices.dropFirst()) { _ in model.reload() }
    }

    private func content(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(meeting)
            status(meeting)
            PlayerBar(player: model.player,
                      hasAudio: meeting.hasAudio || meeting.hasMergedAudio,
                      fallbackDuration: meeting.duration ?? 0,
                      sharedAudio: model.sharedAudio)
            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.message = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
            }
            Picker("", selection: $tab) {
                Text("Notes").tag(Tab.notes)
                Text("Transcript").tag(Tab.transcript)
                Text("People").tag(Tab.people)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .notes:
                ScrollView { NotesTab(model: model, meeting: meeting).padding(.bottom, 12) }
            case .transcript:
                TranscriptTab(model: model, player: model.player)
            case .people:
                ScrollView { PeopleTab(model: model, meeting: meeting).padding(.bottom, 12) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 12)
        .confirmationDialog(L("Delete this meeting?"), isPresented: $confirmDelete) {
            Button(L("Move to Trash"), role: .destructive) {
                store.delete(meeting)
                WindowManager.shared.closeMeeting(meeting.id)
            }
        } message: {
            Text("The whole folder goes to the Trash, so you can still get it back from there.")
        }
    }

    // MARK: Header

    private func header(_ meeting: Meeting) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1)
                Text(meeting.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                if model.participants.count > 1 {
                    Text(model.participants.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                shareMenu(meeting)

                Menu {
                    Button("Copy transcript") { model.copyTranscript() }
                        .disabled(meeting.existingTranscriptURL == nil)
                    Button("Copy notes") { model.copyNotes() }
                        .disabled(model.summary == nil && model.notes.isEmpty)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("Copy"))

                toolbarButton("square.and.arrow.down", help: L("Save as MP3…")) { model.exportMP3() }
                    .disabled(!(meeting.hasAudio || meeting.hasMergedAudio) || model.exporting)
                toolbarButton("folder", help: L("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([meeting.dir])
                }

                Menu {
                    Button("Open transcript in your editor") {
                        if let url = meeting.existingTranscriptURL { NSWorkspace.shared.open(url) }
                    }
                    .disabled(meeting.existingTranscriptURL == nil)
                    TranscribeAgainMenu(meeting: meeting)
                    if FileManager.default.fileExists(atPath: meeting.versionsDir.path) {
                        Button("Show earlier versions") { NSWorkspace.shared.open(meeting.versionsDir) }
                    }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(store.transcribingID == meeting.id)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("More"))
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
    }

    /// AirDrop, Mail, Messages and the rest, for the audio, the transcript or the notes.
    private func shareMenu(_ meeting: Meeting) -> some View {
        Menu {
            if let audio = model.sharedAudio {
                ShareLink(item: audio) { Label("Audio (MP3)", systemImage: "waveform") }
            } else if model.preparingAudio {
                Text("Preparing the audio…")
            }
            if let transcript = model.sharedTranscript {
                ShareLink(item: transcript) { Label("Transcript", systemImage: "doc.text") }
            }
            if !model.notesText.isEmpty {
                ShareLink(item: model.notesText) { Label("Notes", systemImage: "note.text") }
            }
            if let audio = model.sharedAudio, let transcript = model.sharedTranscript {
                ShareLink(items: [audio, transcript]) {
                    Label("Audio and transcript", systemImage: "square.stack")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Share"))
        .disabled(model.sharedAudio == nil && !model.preparingAudio && model.sharedTranscript == nil
                  && model.notesText.isEmpty)
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func status(_ meeting: Meeting) -> some View {
        switch meeting.status {
        case .pending:
            statusRow(L("Waiting to be transcribed…"), progress: nil)
        case .transcribing:
            statusRow(L("Transcribing…"), progress: store.transcribingID == meeting.id ? store.transcribeProgress : nil)
        case .failed:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(meeting.error ?? L("Failed")).font(.system(size: 11)).lineLimit(2)
                Spacer()
                if meeting.hasAudio {
                    Button("Try again") { store.retry(meeting) }.controlSize(.small)
                }
            }
        case .recording:
            statusRow(L("Recording…"), progress: nil)
        case .done:
            EmptyView()
        }
    }

    private func statusRow(_ text: String, progress: Double?) -> some View {
        HStack(spacing: 8) {
            if let progress {
                ProgressView(value: progress).frame(width: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Player

private struct PlayerBar: View {
    @ObservedObject var player: MeetingPlayer
    let hasAudio: Bool
    let fallbackDuration: Double
    /// The meeting as an MP3 named after it, once ready: dragged out of the
    /// player into Mail, Slack or Finder.
    let sharedAudio: URL?

    private var duration: Double { player.duration > 0 ? player.duration : fallbackDuration }

    var body: some View {
        Card {
            if hasAudio {
                HStack(spacing: 12) {
                    skipButton("gobackward.15", by: -15)
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Theme.brand))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(player.isPlaying ? L("Pause") : L("Play the meeting"))
                    skipButton("goforward.15", by: 15)

                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { min(player.time, duration) },
                                              set: { player.seek(to: $0) }),
                               in: 0...max(duration, 1))
                            .controlSize(.small)
                            .disabled(!player.loaded)
                        HStack {
                            Text(Self.clock(player.time)).monospacedDigit()
                            Spacer()
                            Text(verbatim: "-" + Self.clock(max(0, duration - player.time))).monospacedDigit()
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }

                    Menu {
                        ForEach(MeetingPlayer.rates, id: \.self) { rate in
                            Button(Self.rateText(rate)) { player.rate = rate }
                        }
                    } label: {
                        Text(Self.rateText(player.rate)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                    .menuStyle(.button)
                .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("Playback speed"))

                    if let sharedAudio {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(contentsOf: sharedAudio) ?? NSItemProvider() }
                            .help(L("Drag the MP3 into another app"))
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.slash").foregroundStyle(.secondary)
                    Text("The audio of this meeting was not kept.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func skipButton(_ symbol: String, by seconds: Double) -> some View {
        Button { player.skip(by: seconds) } label: {
            Image(systemName: symbol).font(.system(size: 15))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!player.loaded)
    }

    static func clock(_ seconds: Double) -> String {
        Transcriber.timestamp(Int(seconds.isFinite ? seconds * 1000 : 0))
    }

    static func rateText(_ rate: Float) -> String {
        String(format: "%g×", rate)
    }
}

// MARK: - Notes

private struct NotesTab: View {
    @ObservedObject var model: MeetingModel
    let meeting: Meeting
    @AppStorage(Pref.summaryModel) private var summaryModel = Pref.defaultSummaryModel
    @AppStorage(Pref.summaryEngine) private var summaryEngine = "auto"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                heading(L("Summary"))
                summary
            }
            VStack(alignment: .leading, spacing: 8) {
                heading(L("Your notes"))
                TextEditor(text: $model.notes)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
                    .onChange(of: model.notes) { model.notesChanged() }
                Text("Saved as notes.md in the meeting folder, next to the transcript.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let summary = model.summary {
            Text(MeetingNotes.display(summary))
                .font(.system(size: 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.writingNotes {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing notes…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else if model.hasStoredTranscript {
            VStack(alignment: .leading, spacing: 8) {
                Text("No summary yet. Ata can write one, with the decisions and action items.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch Summarizer.engine(preference: summaryEngine, appleAvailable: AppleModel.isAvailable,
                                         hasOpenAIKey: Keychain.has(Keychain.openAIKey)) {
                case .apple?:
                    Button("Write notes on this Mac") { Task { await model.writeNotes() } }
                    Text("Written on this Mac. Nothing leaves it.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                case .openAI?:
                    Button(L("Write notes with %@", summaryModel)) { Task { await model.writeNotes() } }
                    Text("Sends the transcript text to OpenAI. The audio stays on this Mac.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                case nil:
                    if summaryEngine == SummaryEngine.apple.rawValue, let reason = AppleModel.unavailableReason {
                        Text(reason)
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Writing notes needs an OpenAI API key.")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Button("Open Settings") { WindowManager.shared.showSettings() }
                }
            }
        } else {
            Text(meeting.status == .done
                 ? L("This meeting was transcribed before Ata could add notes to it. Transcribe it again to get a summary.")
                 : L("Notes appear here once the meeting is transcribed."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func heading(_ title: String) -> some View {
    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
}

// MARK: - Transcript

private struct TranscriptTab: View {
    @ObservedObject var model: MeetingModel
    @ObservedObject var player: MeetingPlayer
    @State private var query = ""

    private var shown: [MeetingModel.Line] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.lines }
        return model.lines.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// The line being heard right now.
    private var currentID: Int? {
        guard player.isPlaying || player.time > 0 else { return nil }
        let ms = Int(player.time * 1000)
        return model.lines.last { $0.start <= ms }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.lines.isEmpty {
                TextField(L("Search"), text: $query, prompt: Text("Search the transcript"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(shown) { line in
                                LineRow(line: line, current: line.id == currentID, coarse: model.coarse) {
                                    player.seek(to: Double(line.start) / 1000)
                                    player.play()
                                }
                                .id(line.id)
                            }
                            if shown.isEmpty {
                                Text("Nothing in this transcript matches.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .onChange(of: currentID) { _, id in
                        guard player.isPlaying, query.isEmpty, let id else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            } else if let markdown = model.markdown {
                ScrollView {
                    Text(markdown)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                }
            } else {
                Text("The transcript appears here once the meeting is transcribed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct LineRow: View {
    let line: MeetingModel.Line
    let current: Bool
    let coarse: Bool
    let play: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !coarse {
                Button(Transcriber.timestamp(line.start), action: play)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(current ? Color.accentColor : Color.secondary)
                    .help(L("Play from here"))
                    .frame(width: 52, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(line.speaker == Speakers.me ? Theme.meTint : Theme.othersTint)
                Text(line.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(current ? Color.accentColor.opacity(0.12) : Color.clear))
    }
}

// MARK: - People

private struct PeopleTab: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var model: MeetingModel
    let meeting: Meeting
    @AppStorage(Pref.recogniseVoices) private var recognise = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.speakers.isEmpty {
                empty
            } else {
                Text("Name a voice once and every transcript uses the name, this one included.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 2) {
                    ForEach(model.speakers) { SpeakerRow(model: model, speaker: $0) }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.wave.2.fill").font(.system(size: 26)).foregroundStyle(Theme.brand)
            if !recognise {
                Text("Know who said what").font(.system(size: 13, weight: .semibold))
                Text("Ata can tell the other participants apart and learn their voices across meetings. Fingerprints stay on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if Diarization.isSupported {
                    Button(L("Turn on voice recognition")) { recognise = true }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Needs macOS 15 or later.")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                }
            } else {
                Text("No voices for this meeting yet").font(.system(size: 13, weight: .semibold))
                Text("Voices are found while a meeting is transcribed. This one was transcribed before voice recognition was on, or nobody else spoke.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if recognise, meeting.hasAudio, meeting.status == .done || meeting.status == .failed {
                Button("Transcribe again to find the voices") { store.retry(meeting) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }
}

private struct SpeakerRow: View {
    @ObservedObject var model: MeetingModel
    @StateObject private var people = PeopleModel.shared
    let speaker: MeetingModel.Speaker
    @State private var name = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var named: Bool { speaker.voice?.name != nil }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.play(speaker) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(speaker.sampleStart == nil ? AnyShapeStyle(Color.gray.opacity(0.4))
                                                                         : AnyShapeStyle(Theme.brand)))
            }
            .buttonStyle(.plain)
            .disabled(speaker.sampleStart == nil)
            .help(L("Play where they speak longest"))

            VStack(alignment: .leading, spacing: 3) {
                if !editing {
                    Text(speaker.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                if speaker.voice != nil, !named || editing {
                    TextField(L("Name"), text: $name, prompt: Text(L("Type their name…")))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .focused($focused)
                        .onSubmit { save() }
                        .onExitCommand { editing = false; name = "" }
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(L("Save")) { save() }.controlSize(.small)
            } else if named, !editing {
                Button(L("Rename…")) {
                    name = speaker.voice?.name ?? ""
                    editing = true
                    focused = true
                }
                .controlSize(.small)
            }
            if let voice = speaker.voice {
                let others = people.voices.filter { $0.id != voice.id && $0.name != nil }
                if !others.isEmpty {
                    Menu {
                        ForEach(others) { other in
                            Button(other.name ?? "") { model.merge(speaker, into: other) }
                        }
                    } label: {
                        Image(systemName: "person.2")
                    }
                    .menuStyle(.button)
                .buttonStyle(.borderless)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("Same person as"))
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private var detail: String {
        let minutes = Int((speaker.seconds / 60).rounded())
        let talked = minutes < 1 ? L("<1 min") : L("%d min", minutes)
        guard let voice = speaker.voice, voice.meetings > 1 else { return L("Talked for %@", talked) }
        return L("Talked for %@ · in %d meetings", talked, voice.meetings)
    }

    private func save() {
        model.rename(speaker, to: name)
        name = ""
        editing = false
    }
}

// MARK: - Shared

/// "Transcribe again" and "Transcribe again with…", for the row's context
/// menu and the meeting window's menu.
struct TranscribeAgainMenu: View {
    let meeting: Meeting
    /// Not an environment object: context menus don't always carry the environment.
    private var store: AppStore { AppStore.shared }

    var body: some View {
        if meeting.hasAudio && meeting.status != .transcribing && meeting.status != .recording {
            Button("Transcribe again") { store.retry(meeting) }
            Menu("Transcribe again with") {
                Section("On this Mac") {
                    ForEach(LocalModel.all) { model in
                        Button(model.isInstalled ? model.title : L("%@ (not downloaded)", model.title)) {
                            store.retry(meeting, with: TranscribeOverride(engine: Engine.local.rawValue,
                                                                          model: model.id))
                        }
                        .disabled(!model.isInstalled)
                    }
                }
                Section("OpenAI") {
                    ForEach(Pref.openAIModels, id: \.self) { model in
                        Button(model) {
                            store.retry(meeting, with: TranscribeOverride(engine: Engine.openAI.rawValue,
                                                                          model: model))
                        }
                        .disabled(!Keychain.has(Keychain.openAIKey))
                    }
                }
            }
        }
    }
}
