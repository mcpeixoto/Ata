import SwiftUI

/// The menu's third tab: voices Ata has learned, and the ones it would like a name for.
struct PeopleView: View {
    @StateObject private var people = PeopleModel.shared
    @AppStorage(Pref.recogniseVoices) private var enabled = true
    @State private var confirmForgetAll = false
    @State private var open: PeopleList.Row?
    @State private var query = ""

    /// Tall enough for a good few rows, short enough that the menu never runs off a small screen.
    private static let listHeight: CGFloat = 430

    init(open: PeopleList.Row? = nil) {
        _open = State(initialValue: open)
    }

    private static func learnedLine(_ count: Int) -> String {
        if CloudLibrary.isActive { return L("%d voices learned, kept in your iCloud with your meetings.", count) }
        #if os(iOS)
        return L("%d voices learned, all on this iPhone.", count)
        #else
        return L("%d voices learned, all on this Mac.", count)
        #endif
    }

    /// Voice recognition needs macOS 15; every iPhone that runs Ata is new enough,
    /// so this is a Mac sentence and must not say "macOS" on a phone.
    private static var unsupportedLine: String {
        #if os(iOS)
        return L("Voice recognition isn't available on this iPhone.")
        #else
        return L("Needs macOS 15 or later.")
        #endif
    }

    private static var privacyLine: String {
        if CloudLibrary.isActive {
            return L("Voice fingerprints stay in your iCloud, with your meetings, and are never sent anywhere else. Turning this on downloads 21 MB of models once.")
        }
        #if os(iOS)
        return L("Voice fingerprints stay on this iPhone. Turning this on downloads 21 MB of models once.")
        #else
        return L("Voice fingerprints stay on this Mac. Turning this on downloads 21 MB of models once.")
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !enabled {
                off
            } else {
                let empty = people.voices.isEmpty && people.me == nil
                if PeopleList.showsSearch(voiceCount: people.voices.count) {
                    TextField(L("Search voices"), text: $query, prompt: Text(L("Search voices…")))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .ataFont(11)
                }
                let sections = people.sections(query: query)
                scrolling {
                    // In one place for good: it holds a recording of your voice, which
                    // must survive that recording turning into the first voice in the list.
                    you
                    if empty {
                        waiting
                    } else {
                        ForEach(sections, id: \.kind) { list($0) }
                        if sections.isEmpty, !query.isEmpty {
                            Text("No voices match").ataFont(11).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                }
                if !empty { footer }
            }
        }
        .onAppear { people.reload() }
    }

    private var footer: some View {
        HStack {
            Text(Self.learnedLine(people.voices.count))
                .ataFont(10).foregroundStyle(.secondary)
            Spacer()
            Button(confirmForgetAll ? L("Delete all?") : L("Forget all")) {
                if confirmForgetAll { people.forgetAll(); open = nil; confirmForgetAll = false } else {
                    confirmForgetAll = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmForgetAll = false }
                }
            }
            .buttonStyle(.plain)
            .ataFont(10, weight: .medium)
            .foregroundStyle(confirmForgetAll ? .red : .secondary)
        }
    }

    /// The list scrolls on its own in the menu and the window, which do not. The
    /// phone's tab is already a scroll view, and one inside another fights the swipe.
    @ViewBuilder private func scrolling<C: View>(@ViewBuilder content: () -> C) -> some View {
        let rows = VStack(alignment: .leading, spacing: 10) { content() }
        #if os(iOS)
        rows
        #else
        ScrollViewReader { proxy in
            ScrollView {
                rows.padding(.trailing, 2)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Only as tall as the rows, up to the limit: a short list leaves no gap.
            .frame(maxHeight: Self.listHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: open) { _, row in
                guard let row else { return }
                // After the row has grown, or it scrolls to where it used to end.
                DispatchQueue.main.async {
                    proxy.scrollTo(row)
                }
            }
        }
        #endif
    }

    // Always first, and always there. Your name and your voice are the one thing
    // Ata cannot work out on its own, and everything else here is told apart around them.
    private var you: some View {
        section(L("You"), count: nil, footnote: nil) {
            YouRow(voice: people.me, playing: people.me.map { people.playing == $0.id } ?? false,
                   isOpen: open == .you) { toggle(.you) }
                .id(PeopleList.Row.you)
        }
    }

    private func list(_ section: PeopleList.Section) -> some View {
        self.section(Self.title(section.kind), count: section.kind == .asking ? section.voices.count : nil,
                     footnote: section.notShown > 0 ? L("%d more. Search to find them.", section.notShown) : nil) {
            ForEach(section.voices) { voice in
                VoiceRow(people: people, voice: voice, playing: people.playing == voice.id,
                         isOpen: open == .voice(voice.id)) { toggle(.voice(voice.id)) }
                    .id(PeopleList.Row.voice(voice.id))
            }
        }
    }

    private func toggle(_ row: PeopleList.Row) {
        open = PeopleList.toggled(open, row)
    }

    private static func title(_ kind: PeopleList.Kind) -> String {
        switch kind {
        case .asking: return L("Who's this?")
        case .heardOnce: return L("Heard once")
        case .named: return L("People")
        case .hidden: return L("Hidden voices")
        case .results: return L("Voices")
        }
    }

    private var off: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.wave.2.fill")
                .ataFont(30)
                .foregroundStyle(Theme.brand)
            Text("Know who said what").ataFont(14, weight: .semibold)
            Text("Ata can tell the other participants apart and learn their voices across meetings. You name a voice once; every transcript uses the name from then on.")
                .ataFont(11).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.privacyLine)
                .ataFont(10).ataFaint()
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if Diarization.isSupported {
                Button(L("Turn on voice recognition")) { enabled = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            } else {
                Text(Self.unsupportedLine)
                    .ataFont(11, weight: .semibold).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
    }

    /// What happens next, and — on a phone, where Ata can never learn your voice
    /// from a call's microphone — the one thing only you can tell it.
    private static var waitingLine: String {
        #if os(iOS)
        return L("Voices show up here after your next meetings are transcribed. Ata asks about a voice once it has heard it in at least two meetings. Mark your own voice as yours once, and every meeting in the room can tell you from everyone else.")
        #else
        return L("Voices show up here after your next meetings are transcribed. Ata asks about a voice once it has heard it in at least two meetings.")
        #endif
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .ataFont(26).foregroundStyle(Theme.brand)
            Text("Listening for voices").ataFont(13, weight: .semibold)
            Text(Self.waitingLine)
                .ataFont(11).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private func section<C: View>(_ title: String, count: Int?, footnote: String?,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title.uppercased()).ataFont(9, weight: .semibold).foregroundStyle(.secondary)
                if let count { Text("\(count)").ataFont(9, weight: .semibold).foregroundStyle(Theme.brand) }
            }
            VStack(spacing: 0) { content() }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
            if let footnote {
                Text(footnote).ataFont(10).foregroundStyle(.secondary)
            }
        }
    }
}

/// The round play button every row starts with.
private struct PlayButton: View {
    let hasSample: Bool
    let playing: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Image(systemName: playing ? "stop.fill" : "play.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hasSample ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.gray.opacity(0.4))))
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
        .disabled(!hasSample)
        .help(L("Play a sample"))
        .accessibilityLabel(L("Play a sample"))
    }
}

/// The part of a row that opens it: a name, one line under it, and which way it goes.
private struct RowHeading: View {
    let title: String
    let detail: String
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).ataFont(12, weight: .semibold).lineLimit(1)
                    Text(detail).ataFont(10).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .ataFont(9, weight: .semibold)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? L("Open") : L("Closed"))
    }
}

/// When a voice was last heard, in the words its row shows.
private func heard(_ voice: Voice) -> String {
    let when = voice.lastSeen.formatted(.relative(presentation: .named))
    return voice.meetings == 1 ? L("1 meeting · heard %@", when) : L("%d meetings · heard %@", voice.meetings, when)
}

/// One voice, on one line until it is opened. Takes the model as a plain value:
/// a row only draws again when what it shows changes, not on every change to any voice.
private struct VoiceRow: View {
    let people: PeopleModel
    let voice: Voice
    let playing: Bool
    let isOpen: Bool
    let toggle: () -> Void

    private var detail: String {
        if voice.isExcluded { return L("Left out of transcripts") }
        if voice.isDismissed && voice.name == nil { return L("Not asked about") }
        return heard(voice)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PlayButton(hasSample: voice.sample != nil, playing: playing) { people.togglePlay(voice) }
                RowHeading(title: voice.displayName, detail: detail, isOpen: isOpen, toggle: toggle)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            if isOpen {
                VoiceDetail(people: people, voice: voice, close: toggle)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// Everything you can do to one voice, in the open row. Only the open row works
/// out suggestions, so a long list costs nothing for the voices nobody is looking at.
private struct VoiceDetail: View {
    @ObservedObject var people: PeopleModel
    let voice: Voice
    let close: () -> Void
    @State private var name: String
    @State private var confirmForget = false
    @FocusState private var focused: Bool

    init(people: PeopleModel, voice: Voice, close: @escaping () -> Void) {
        self.people = people
        self.voice = voice
        self.close = close
        _name = State(initialValue: voice.name ?? "")
    }

    private var typed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField(L("Name"), text: $name, prompt: Text(L("Type their name…")))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .ataFont(11)
                    .focused($focused)
                    .onSubmit { save() }
                    .onExitCommand { close() }
                if !typed.isEmpty && typed != voice.name {
                    Button(L("Save")) { save() }.controlSize(.small)
                }
            }
            if voice.name == nil { suggestions }
            actions
        }
        .onAppear {
            // A voice with no name is opened to name it. On the next pass: the field
            // has to be in the window before it can take the focus.
            guard voice.name == nil else { return }
            DispatchQueue.main.async { focused = true }
        }
    }

    /// In full view: none of this should depend on knowing to right-click.
    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 2) {
            let targets = people.mergeTargets(for: voice)
            if !targets.isEmpty {
                Menu {
                    ForEach(targets) { other in
                        Button(other.displayName) {
                            people.merge(voice, into: other, redraw: .background)
                            close()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        ActionLabel(title: L("Same person as"), symbol: "person.2")
                        Image(systemName: "chevron.up.chevron.down").ataFont(8, weight: .semibold)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .fixedSize()
            }
            action(L("This is me"), "person.crop.circle") { people.setMe(voice, true, redraw: .background) }
            if voice.name == nil {
                if voice.isDismissed {
                    action(L("Ask again"), "questionmark.circle") { people.dismiss(voice, false) }
                } else {
                    action(L("Don't ask about this voice"), "bell.slash") { people.dismiss(voice) }
                }
            }
            if voice.isExcluded {
                action(L("Put back"), "text.badge.plus") { people.setExcluded(voice, false, redraw: .background) }
            } else {
                action(L("Leave out of transcripts"), "text.badge.minus") { people.setExcluded(voice, true, redraw: .background) }
            }
            Button {
                if confirmForget {
                    people.forget(voice, redraw: .background)
                    close()
                } else {
                    confirmForget = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmForget = false }
                }
            } label: {
                ActionLabel(title: confirmForget ? L("Forget this voice?") : L("Forget this voice"), symbol: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button {
            perform()
            close()
        } label: {
            ActionLabel(title: title, symbol: symbol)
        }
        .buttonStyle(.plain)
    }

    /// Who the calendar says this might be.
    ///
    /// One tap names the voice, down the same path as typing it, so every
    /// transcript is redrawn. The reason is on the row rather than in a
    /// tooltip: a name Ata guessed and the user did not check is the one thing
    /// this must never produce, so the evidence is always in front of them.
    @ViewBuilder private var suggestions: some View {
        let offered = Array(people.suggestions(for: voice).prefix(3))
        if !offered.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(offered) { candidate in
                    HStack(spacing: 6) {
                        Button(candidate.name) {
                            if candidate.matchesExistingVoice >= .reordered,
                               let other = people.voices.first(where: { other in
                                   other.id != voice.id && other.allNames.contains {
                                       Names.compare($0, candidate.name) >= .reordered
                                   }
                               }) {
                                // Already a voice with that name: the user wants
                                // these two folded together, not a second copy.
                                people.merge(voice, into: other, redraw: .background)
                            } else {
                                people.accept(candidate, for: voice, redraw: .background)
                            }
                            close()
                        }
                        .controlSize(.small)
                        Text(Self.reason(candidate))
                            .ataFont(9).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    /// Why this name is being offered, in a few words.
    private static func reason(_ c: VoiceSuggestions.Candidate) -> String {
        if c.matchesExistingVoice >= .reordered { return L("already a voice — same person?") }
        if c.isOnlyOther { return L("the only other person invited") }
        if c.isUnanimous && c.heardInEvents > 1 { return L("invited to all %d", c.heardInEvents) }
        if c.isUnanimous { return L("invited to it") }
        return L("invited to %d of %d", c.shared, c.heardInEvents)
    }

    private func save() {
        guard !typed.isEmpty, typed != voice.name else { return }
        people.rename(voice, to: typed, redraw: .background)
        close()
    }
}

/// One line of an open row, with every icon in the same width so the words line up.
private struct ActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).ataFont(11).frame(width: 18)
            Text(title).ataFont(11)
        }
        .padding(.vertical, 3)
        #if os(iOS)
        .frame(minHeight: 44)
        #endif
        .contentShape(Rectangle())
    }
}

/// You: the name your lines carry, and the voice Ata tells you by. Open it to change
/// either, and it stays open while it is recording you, whichever row you tap.
private struct YouRow: View {
    @StateObject private var people = PeopleModel.shared
    @StateObject private var enrolment = VoiceEnrolment()
    @AppStorage(Pref.myName) private var myName = ""
    /// Nil until Ata knows which voice is yours.
    let voice: Voice?
    let playing: Bool
    let isOpen: Bool
    let toggle: () -> Void

    /// Recording you, or telling you it could not: never hidden by another row opening.
    private var enrolling: Bool {
        switch enrolment.phase {
        case .recording, .learning, .failed: return true
        case .idle, .done: return false
        }
    }

    /// Said when Ata already knows which voice is yours.
    private static let youLine = L("Ata knows this voice is you, so it tells you apart from everyone else in the room.")

    /// Said when it does not. On a phone this is the only way in: it records one
    /// track, so there is never a call's microphone to learn you from.
    private static var enrolLine: String {
        #if os(iOS)
        return L("Read one short paragraph and Ata knows your voice from then on — in a room full of people, from the very first meeting.")
        #else
        return L("Read one short paragraph and Ata knows your voice from then on, without waiting to learn it from a call.")
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                PlayButton(hasSample: voice?.sample != nil, playing: playing) {
                    if let voice { people.togglePlay(voice) }
                }
                RowHeading(title: myName.isEmpty ? L("Me") : myName,
                           detail: voice.map(heard) ?? L("Your voice isn't recorded yet"),
                           isOpen: isOpen, toggle: toggle)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            if isOpen || enrolling {
                VStack(alignment: .leading, spacing: 8) {
                    if isOpen {
                        TextField(L("Your name"), text: $myName, prompt: Text(L("Me")))
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .ataFont(11)
                            .accessibilityLabel(L("Your name in the transcript"))
                        Text(voice == nil ? Self.enrolLine : Self.youLine)
                            .ataFont(10).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        enrol
                        if isOpen, !enrolling, let voice {
                            Button(L("Not me")) {
                                people.setMe(voice, false, redraw: .background)
                                toggle()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    /// Recording your voice: the paragraph to read, a countdown, and what came of it.
    @ViewBuilder private var enrol: some View {
        switch enrolment.phase {
        case .recording:
            VStack(alignment: .leading, spacing: 5) {
                Text(VoiceEnrolment.prompt)
                    .ataFont(11)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ProgressView(value: min(1, enrolment.seconds / VoiceEnrolment.targetSeconds))
                        .frame(maxWidth: 120)
                    Text(L("%d s left", Int((VoiceEnrolment.targetSeconds - enrolment.seconds).rounded(.up))))
                        .ataFont(10).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(L("Stop")) { enrolment.cancel() }.controlSize(.small)
                }
            }
        case .learning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Learning your voice…").ataFont(10).foregroundStyle(.secondary)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Text(why).ataFont(10).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Try again")) { enrolment.start() }.controlSize(.small)
            }
        case .idle, .done:
            Button(voice == nil ? L("Record my voice") : L("Record my voice again")) { enrolment.start() }
                .controlSize(.small)
        }
    }
}
