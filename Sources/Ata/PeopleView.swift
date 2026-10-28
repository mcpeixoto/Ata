import SwiftUI

/// The menu's third tab: voices Ata has learned, and the ones it would like a name for.
struct PeopleView: View {
    @StateObject private var people = PeopleModel.shared
    @AppStorage(Pref.recogniseVoices) private var enabled = true
    @State private var confirmForgetAll = false

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

    private static var privacyLine: String {
        if CloudLibrary.isActive {
            return L("Voice fingerprints stay in your iCloud, with your meetings, and are never sent anywhere else. Turning this on downloads 21 MB of models once.")
        }
        #if os(iOS)
        return L("Voice fingerprints stay on this iPhone. Turning this on downloads 21 MB of models once.")
        #else
        return L("Voice fingerprints stay on this Mac, even when OpenAI transcribes. Turning this on downloads 21 MB of models once.")
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !enabled {
                off
            } else {
                // Always first, and always there. Your name and your voice are the
                // one thing Ata cannot work out on its own, and everything else on
                // this tab is told apart around them.
                section(L("You"), footnote: people.me == nil ? Self.enrolLine : Self.youLine) {
                    YouRow(voice: people.me)
                }
            }
            if enabled, people.voices.isEmpty, people.me == nil {
                waiting
            } else if enabled {
                if !people.worthAsking.isEmpty {
                    section(L("Who's this?"), footnote: L("Heard in several meetings. Play a sample, then type a name.")) {
                        ForEach(people.worthAsking) { VoiceRow(voice: $0, asking: true) }
                    }
                }
                if !people.heardOnce.isEmpty {
                    section(L("Heard once"), footnote: L("Ata asks for a name once it has heard a voice in two meetings. You can name one now anyway — or say it's you.")) {
                        ForEach(people.heardOnce) { VoiceRow(voice: $0, asking: true) }
                    }
                }
                if !people.named.isEmpty {
                    section(L("People"), footnote: nil) {
                        ForEach(people.named) { VoiceRow(voice: $0, asking: false) }
                    }
                }
                if !people.hidden.isEmpty {
                    section(L("Hidden voices"), footnote: L("Not asked about, or left out of every transcript.")) {
                        ForEach(people.hidden) { HiddenVoiceRow(voice: $0) }
                    }
                }
                HStack {
                    Text(Self.learnedLine(people.voices.count))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button(confirmForgetAll ? L("Delete all?") : L("Forget all")) {
                        if confirmForgetAll { people.forgetAll(); confirmForgetAll = false } else {
                            confirmForgetAll = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmForgetAll = false }
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(confirmForgetAll ? .red : .secondary)
                }
            }
        }
        .onAppear { people.reload() }
    }

    private var off: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.brand)
            Text("Know who said what").font(.system(size: 14, weight: .semibold))
            Text("Ata can tell the other participants apart and learn their voices across meetings. You name a voice once; every transcript uses the name from then on.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.privacyLine)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if Diarization.isSupported {
                Button(L("Turn on voice recognition")) { enabled = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            } else {
                Text(Self.unsupportedLine)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
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
                .font(.system(size: 26)).foregroundStyle(Theme.brand)
            Text("Listening for voices").font(.system(size: 13, weight: .semibold))
            Text(Self.waitingLine)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private func section<C: View>(_ title: String, footnote: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            if let footnote {
                Text(footnote).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) { content() }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

private struct VoiceRow: View {
    @StateObject private var people = PeopleModel.shared
    let voice: Voice
    let asking: Bool
    @State private var name = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { people.togglePlay(voice) } label: {
                Image(systemName: people.playing == voice.id ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(voice.sample == nil ? AnyShapeStyle(Color.gray.opacity(0.4))
                                                                   : AnyShapeStyle(Theme.brand)))
            }
            .buttonStyle(.plain)
            .disabled(voice.sample == nil)
            .help(L("Play a sample"))
            .accessibilityLabel(L("Play a sample"))

            VStack(alignment: .leading, spacing: 3) {
                if asking {
                    Text(voice.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                } else if !editing {
                    Text(voice.name ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                if asking || editing {
                    TextField(L("Name"), text: $name, prompt: Text(L("Type their name…")))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11))
                        .focused($focused)
                        .onSubmit { save() }
                        .onExitCommand { editing = false; name = "" }
                }
                if asking { suggestions }
                Text(L("%d meetings · heard %@", voice.meetings,
                       voice.lastSeen.formatted(.relative(presentation: .named))))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if (asking || editing) && !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(L("Save")) { save() }.controlSize(.small)
            } else if asking {
                Button { people.dismiss(voice) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Don't ask about this voice"))
                .accessibilityLabel(L("Don't ask about this voice"))
            }
            #if os(iOS)
            Menu { actions } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("More"))
            #endif
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contextMenu { actions }
    }

    /// Everything you can do to a voice. A right-click finds these on the Mac;
    /// on a phone there is no right-click, so the same list is behind the
    /// visible button above.
    @ViewBuilder private var actions: some View {
        if !asking {
            Button(L("Rename…")) {
                name = voice.name ?? ""
                editing = true
                focused = true
            }
        }
        Button(L("This is me")) { people.setMe(voice, true) }
        Menu(L("Same person as")) {
            ForEach(people.voices.filter { $0.id != voice.id && $0.name != nil }) { other in
                Button(other.name ?? "") { people.merge(voice, into: other) }
            }
        }
        if voice.name == nil {
            Button(L("Don't ask about this voice")) { people.dismiss(voice) }
        }
        Button(L("Leave out of transcripts")) { people.setExcluded(voice, true) }
        Divider()
        Button(L("Forget this voice"), role: .destructive) { people.forget(voice) }
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
                                people.merge(voice, into: other)
                            } else {
                                people.accept(candidate, for: voice)
                            }
                        }
                        .controlSize(.small)
                        Text(Self.reason(candidate))
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.top, 1)
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
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        people.rename(voice, to: trimmed)
        name = ""
        editing = false
    }
}

/// Your own voice, once you have marked one — with the way back, because the
/// first tap is a guess the user is allowed to take back.
/// You: the name your lines carry, and the voice Ata tells you by.
private struct YouRow: View {
    @StateObject private var people = PeopleModel.shared
    @StateObject private var enrolment = VoiceEnrolment()
    @AppStorage(Pref.myName) private var myName = ""
    /// Nil until Ata knows which voice is yours.
    let voice: Voice?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { if let voice { people.togglePlay(voice) } } label: {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(voice?.sample == nil ? AnyShapeStyle(Color.gray.opacity(0.4))
                                                                       : AnyShapeStyle(Theme.brand)))
                }
                .buttonStyle(.plain)
                .disabled(voice?.sample == nil)
                .help(L("Play a sample"))
                .accessibilityLabel(L("Play a sample"))

                TextField(L("Your name"), text: $myName, prompt: Text(L("Me")))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .frame(maxWidth: 160)
                    .accessibilityLabel(L("Your name in the transcript"))

                Spacer(minLength: 4)

                if let voice {
                    Button(L("Not me")) { people.setMe(voice, false) }
                        .controlSize(.small)
                }
            }

            if let voice {
                Text(L("%d meetings · heard %@", voice.meetings,
                       voice.lastSeen.formatted(.relative(presentation: .named))))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 4)
            }

            enrol
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private var playing: Bool { voice.map { people.playing == $0.id } ?? false }

    /// Recording your voice: the paragraph to read, a countdown, and what came of it.
    @ViewBuilder private var enrol: some View {
        switch enrolment.phase {
        case .recording:
            VStack(alignment: .leading, spacing: 5) {
                Text(VoiceEnrolment.prompt)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ProgressView(value: min(1, enrolment.seconds / VoiceEnrolment.targetSeconds))
                        .frame(maxWidth: 120)
                    Text(L("%d s left", Int((VoiceEnrolment.targetSeconds - enrolment.seconds).rounded(.up))))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(L("Stop")) { enrolment.cancel() }.controlSize(.small)
                }
            }
            .padding(.horizontal, 4)
        case .learning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Learning your voice…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Text(why).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Try again")) { enrolment.start() }.controlSize(.small)
            }
            .padding(.horizontal, 4)
        case .idle, .done:
            Button(voice == nil ? L("Record my voice") : L("Record my voice again")) { enrolment.start() }
                .controlSize(.small)
                .padding(.leading, 4)
        }
    }
}

/// A voice that is not asked about or is left out of transcripts, with the way back.
private struct HiddenVoiceRow: View {
    @StateObject private var people = PeopleModel.shared
    let voice: Voice

    var body: some View {
        HStack(spacing: 8) {
            Button { people.togglePlay(voice) } label: {
                Image(systemName: people.playing == voice.id ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(voice.sample == nil ? AnyShapeStyle(Color.gray.opacity(0.4))
                                                                   : AnyShapeStyle(Color.secondary)))
            }
            .buttonStyle(.plain)
            .disabled(voice.sample == nil)
            .help(L("Play a sample"))
            .accessibilityLabel(L("Play a sample"))

            VStack(alignment: .leading, spacing: 2) {
                Text(voice.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(voice.isExcluded ? L("Left out of transcripts") : L("Not asked about"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(voice.isExcluded ? L("Put back") : L("Ask again")) {
                if voice.isExcluded { people.setExcluded(voice, false) } else { people.dismiss(voice, false) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contextMenu {
            if !voice.isExcluded {
                Button(L("Leave out of transcripts")) { people.setExcluded(voice, true) }
            }
            Divider()
            Button(L("Forget this voice"), role: .destructive) { people.forget(voice) }
        }
    }
}
