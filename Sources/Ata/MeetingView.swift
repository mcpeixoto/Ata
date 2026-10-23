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
        #if os(macOS)
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        #else
        // A phone screen is narrower than the Mac window's minimum.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
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
                      sharedAudio: model.sharedAudio,
                      waveform: model.waveform,
                      marks: model.moments.map(\.bookmark.ms))
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
                TranscriptTab(model: model)
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
                toolbarButton("folder", help: Self.revealTitle) {
                    Platform.actions.reveal(meeting.dir)
                }

                Menu {
                    Button("Open transcript in your editor") {
                        if let url = meeting.existingTranscriptURL { Platform.actions.open(url) }
                    }
                    .disabled(meeting.existingTranscriptURL == nil)
                    TranscribeAgainMenu(meeting: meeting)
                    if FileManager.default.fileExists(atPath: meeting.versionsDir.path) {
                        Button("Show earlier versions") { Platform.actions.open(meeting.versionsDir) }
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

    private static var revealTitle: String {
        #if os(iOS)
        return L("Show in Files")
        #else
        return L("Show in Finder")
        #endif
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
    /// You and the others over time; nil while it is being computed.
    let waveform: Waveform?
    /// Moments marked while recording, in ms.
    var marks: [Int] = []

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
                        WaveformView(waveform: waveform, duration: duration, time: min(player.time, duration),
                                     marks: marks) {
                            player.seek(to: $0)
                        }
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
            if !model.moments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    heading(L("Moments you marked"))
                    ForEach(model.moments) { moment in
                        MomentRow(moment: moment, playable: meeting.hasAudio || meeting.hasMergedAudio) {
                            model.play(moment)
                        }
                    }
                }
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
                    #if os(iOS)
                    Button("Write notes on this iPhone") { Task { await model.writeNotes() } }
                    Text("Written on this iPhone. Nothing leaves it.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    #else
                    Button("Write notes on this Mac") { Task { await model.writeNotes() } }
                    Text("Written on this Mac. Nothing leaves it.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    #endif
                case .openAI?:
                    Button(L("Write notes with %@", summaryModel)) { Task { await model.writeNotes() } }
                    #if os(iOS)
                    Text("Sends the transcript text to OpenAI. The audio stays on this iPhone.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    #else
                    Text("Sends the transcript text to OpenAI. The audio stays on this Mac.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    #endif
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

/// One marked moment: its time, what was being said, and its note. Clicking plays from there.
private struct MomentRow: View {
    let moment: MeetingModel.Moment
    let playable: Bool
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: play) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(.orange)
                Text(verbatim: Transcriber.timestamp(moment.bookmark.ms))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    if let line = moment.line {
                        Text(Self.said(line))
                            .font(.system(size: 12))
                            .lineLimit(2)
                    } else if moment.bookmark.note == nil {
                        Text("The transcript will show what was said here.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if let note = moment.bookmark.note {
                        Text(verbatim: note).font(.system(size: 11)).italic().foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if playable && hover {
                    Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hover && playable ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!playable)
        .onHover { hover = $0 }
        .help(playable ? L("Play from here") : "")
    }

    /// "Name: what they said", the name in bold.
    private static func said(_ line: MeetingModel.Line) -> AttributedString {
        var name = AttributedString(line.name + ": ")
        name.inlinePresentationIntent = .stronglyEmphasized
        return name + AttributedString(line.text)
    }
}

private func heading(_ title: String) -> some View {
    Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
}

// MARK: - Transcript

private struct TranscriptTab: View {
    @ObservedObject var model: MeetingModel
    @State private var query = ""

    private var shown: [MeetingModel.Line] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.lines }
        return model.lines.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }
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
                                let current = model.cursor?.line == line.id
                                LineRow(line: line, word: current ? model.cursor?.word : nil,
                                        current: current, coarse: model.coarse)
                                    .equatable()
                                    .id(line.id)
                            }
                            if shown.isEmpty {
                                Text("Nothing in this transcript matches.")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .onChange(of: model.cursor?.line) { _, id in
                        guard model.playing, query.isEmpty, let id else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                // Every word and timestamp is an ata-seek link: clicking one plays from there.
                .environment(\.openURL, OpenURLAction { url in
                    guard let ms = SeekLink.ms(url) else { return .systemAction }
                    MainActor.assumeIsolated { model.play(fromMs: ms) }
                    return .handled
                })
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

/// One block of the transcript. Equatable, so only the line being heard redraws
/// as playback moves from word to word.
private struct LineRow: View, Equatable {
    let line: MeetingModel.Line
    /// The word being heard, when this is the current line.
    let word: Int?
    let current: Bool
    let coarse: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if !coarse {
                Text(Self.timestamp(line))
                    .font(.system(size: 11, design: .monospaced))
                    .tint(current ? Color.accentColor : Color.secondary)
                    .help(L("Play from here"))
                    .frame(width: 52, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(line.speaker == Speakers.me ? Theme.meTint : Theme.othersTint)
                Text(Self.text(line, word: word, linked: !coarse))
                    .font(.system(size: 13))
                    .tint(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(current ? Color.accentColor.opacity(0.08) : Color.clear))
    }

    static func timestamp(_ line: MeetingModel.Line) -> AttributedString {
        var a = AttributedString(Transcriber.timestamp(line.start))
        a.link = SeekLink.url(ms: line.start)
        return a
    }

    /// The line as links, one per word. While it plays, the word being heard is
    /// highlighted and the words still to come are dimmed, like lyrics.
    static func text(_ line: MeetingModel.Line, word: Int?, linked: Bool) -> AttributedString {
        guard linked, !line.words.isEmpty else { return AttributedString(line.text) }
        var out = AttributedString()
        for (i, w) in line.words.enumerated() {
            if i > 0 { out.append(AttributedString(" ")) }
            var a = AttributedString(w.text)
            a.link = SeekLink.url(ms: w.start)
            if let word {
                if i == word {
                    a.backgroundColor = Color.accentColor.opacity(0.3)
                } else if i > word {
                    a.foregroundColor = Color.secondary
                }
            }
            out.append(a)
        }
        return out
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

    private static var voicesPitch: String {
        if CloudLibrary.isActive {
            return L("Ata can tell the other participants apart and learn their voices across meetings. Fingerprints stay in your iCloud, with your meetings.")
        }
        #if os(iOS)
        return L("Ata can tell the other participants apart and learn their voices across meetings. Fingerprints stay on this iPhone.")
        #else
        return L("Ata can tell the other participants apart and learn their voices across meetings. Fingerprints stay on this Mac.")
        #endif
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.wave.2.fill").font(.system(size: 26)).foregroundStyle(Theme.brand)
            if !recognise {
                Text("Know who said what").font(.system(size: 13, weight: .semibold))
                Text(Self.voicesPitch)
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
                Menu {
                    if voice.name == nil {
                        Button(voice.isDismissed ? L("Ask again") : L("Don't ask about this voice")) {
                            model.dismiss(speaker, !voice.isDismissed)
                        }
                    }
                    Button(voice.isExcluded ? L("Put back in transcripts") : L("Leave out of transcripts")) {
                        model.exclude(speaker, !voice.isExcluded)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("More"))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .opacity(speaker.voice?.isExcluded == true ? 0.55 : 1)
    }

    private var detail: String {
        if speaker.voice?.isExcluded == true { return L("Left out of transcripts") }
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
            #if os(iOS)
            // The phone has one engine: Apple's, on the device.
            #else
            Menu("Transcribe again with") {
                Section("On this Mac") {
                    ForEach(LocalModel.all) { model in
                        Button(model.isInstalled ? model.title : L("%@ (not downloaded)", model.title)) {
                            store.retry(meeting, with: TranscribeOverride(engine: Engine.local.rawValue,
                                                                          model: model.id))
                        }
                        .disabled(!model.isInstalled)
                    }
                    Button(L("Apple speech recognition")) {
                        store.retry(meeting, with: TranscribeOverride(engine: Engine.apple.rawValue,
                                                                      model: AppleSpeechEngine.modelID))
                    }
                    .disabled(!AppleSpeechEngine.isAvailable)
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
            #endif
        }
    }
}

/// The meeting's loudness over time, mirrored: the others above the line, you
/// below. What has been played is solid; click or drag anywhere to jump there.
struct WaveformView: View {
    let waveform: Waveform?
    let duration: Double
    let time: Double
    /// Moments marked while recording, in ms: drawn as flags over the lanes.
    var marks: [Int] = []
    let seek: (Double) -> Void
    @State private var hover: CGFloat?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let mid = size.height / 2
                guard let waveform, waveform.count > 0, duration > 0 else {
                    context.fill(Path(CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)),
                                 with: .color(Color.primary.opacity(0.15)))
                    return
                }
                let step: CGFloat = 3
                let columns = max(1, Int(size.width / step))
                let played = size.width * CGFloat(time / duration)
                let msPerColumn = duration * 1000 / Double(columns)
                for c in 0..<columns {
                    let lo = min(waveform.count - 1, Int(Double(c) * msPerColumn) / Waveform.bucketMs)
                    let hi = min(waveform.count, max(lo + 1, Int(Double(c + 1) * msPerColumn) / Waveform.bucketMs))
                    let up = CGFloat(waveform.others[lo..<hi].max() ?? 0) / 255
                    let down = CGFloat(waveform.me[lo..<hi].max() ?? 0) / 255
                    let x = CGFloat(c) * step
                    let alpha = x <= played ? 1.0 : 0.35
                    let hUp = max(1, up * (mid - 1)), hDown = max(1, down * (mid - 1))
                    context.fill(Path(roundedRect: CGRect(x: x, y: mid - hUp, width: 2, height: hUp), cornerRadius: 1),
                                 with: .color(Theme.othersTint.opacity(alpha)))
                    context.fill(Path(roundedRect: CGRect(x: x, y: mid, width: 2, height: hDown), cornerRadius: 1),
                                 with: .color(Theme.meTint.opacity(alpha)))
                }
                context.fill(Path(CGRect(x: min(played, size.width - 1), y: 0, width: 1.5, height: size.height)),
                             with: .color(Color.primary.opacity(0.8)))
                if let hover {
                    context.fill(Path(CGRect(x: hover, y: 0, width: 1, height: size.height)),
                                 with: .color(Color.primary.opacity(0.3)))
                }
            }
            .overlay {
                if duration > 0, !marks.isEmpty {
                    Canvas { context, size in
                        for ms in marks {
                            let x = min(max(0, size.width * CGFloat(Double(ms) / 1000 / duration)), size.width - 1)
                            context.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: size.height)),
                                         with: .color(Color.orange.opacity(0.7)))
                            var flag = Path()
                            flag.move(to: CGPoint(x: x - 3.5, y: 0))
                            flag.addLine(to: CGPoint(x: x + 3.5, y: 0))
                            flag.addLine(to: CGPoint(x: x, y: 5))
                            flag.closeSubpath()
                            context.fill(flag, with: .color(.orange))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if let hover, duration > 0 {
                    Text(Transcriber.timestamp(Int(Double(hover / geo.size.width) * duration * 1000)))
                        .font(.system(size: 9, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.regularMaterial))
                        .offset(x: min(max(0, hover - 16), geo.size.width - 36), y: -2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard duration > 0, geo.size.width > 0 else { return }
                seek(Double(min(max(0, g.location.x / geo.size.width), 1)) * duration)
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p.x
                case .ended: hover = nil
                }
            }
        }
        .frame(height: 40)
        .help(L("You below, the others above. Click to jump."))
    }
}
