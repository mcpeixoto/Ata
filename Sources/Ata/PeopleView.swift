import SwiftUI

/// The menu's third tab: voices Ata has learned, and the ones it would like a name for.
struct PeopleView: View {
    @StateObject private var people = PeopleModel.shared
    @AppStorage(Pref.recogniseVoices) private var enabled = false
    @State private var confirmForgetAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !enabled {
                off
            } else if people.voices.filter({ !$0.isMe }).isEmpty {
                waiting
            } else {
                if !people.worthAsking.isEmpty {
                    section(L("Who's this?"), footnote: L("Heard in several meetings. Play a sample, then type a name.")) {
                        ForEach(people.worthAsking) { VoiceRow(voice: $0, asking: true) }
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
                    Text(L("%d voices learned, all on this Mac.", people.voices.count))
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
            Text("Voice fingerprints stay on this Mac, even when OpenAI transcribes. Turning this on downloads 21 MB of models once.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if Diarization.isSupported {
                Button(L("Turn on voice recognition")) { enabled = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            } else {
                Text("Needs macOS 15 or later.")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 6)
    }

    private var waiting: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(Theme.brand)
            Text("Listening for voices").font(.system(size: 13, weight: .semibold))
            Text("Voices show up here after your next meetings are transcribed. Ata asks about a voice once it has heard it in at least two meetings.")
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
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contextMenu {
            if !asking {
                Button(L("Rename…")) {
                    name = voice.name ?? ""
                    editing = true
                    focused = true
                }
            }
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
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        people.rename(voice, to: trimmed)
        name = ""
        editing = false
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
