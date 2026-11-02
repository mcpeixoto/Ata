import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The menu's third tab: voices Ata has learned, and the ones it would like a name for.
struct PeopleView: View {
    /// In Ata's own window the list fills the space under the tab bar and
    /// scrolls. The menu bar panel stays only as tall as it needs to be.
    var fills: Bool = false

    @StateObject private var people = PeopleModel.shared
    @AppStorage(Pref.recogniseVoices) private var enabled = true
    @State private var confirmForgetAll = false
    @State private var merging: Voice?
    @State private var query = ""
    @State private var showHidden = false

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
        return L("Voice fingerprints stay on this Mac. Turning this on downloads 21 MB of models once.")
        #endif
    }

    var body: some View {
        main
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .onAppear { people.reload() }
            .onChange(of: people.voices) { _, voices in
                // The voice being merged can disappear under us (a merge on
                // another device, or Forget). Leaving the picker up would
                // offer a person who is already gone.
                guard let merging else { return }
                if !voices.contains(where: { $0.id == merging.id }) { self.merging = nil }
            }
        #if os(iOS)
            .sheet(item: $merging) { source in
                // A fixed list height, not a flexible one: a sheet does not
                // hand the picker a bounded height, so a flexible scroll would
                // grow with every voice and run off the phone.
                MergeVoicePicker(source: source, voices: people.voices,
                                 suggested: people.sameAs(source), fills: false,
                                 maxListHeight: 420,
                                 onMerge: { target in
                                     people.merge(source, into: target)
                                     merging = nil
                                 },
                                 onCancel: { merging = nil })
                    .id(source.id)
                    .padding(16)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        #endif
    }

    @ViewBuilder private var main: some View {
        #if os(macOS)
        // The menu bar has no room for a second window, so merging replaces
        // the list in place. A phone presents the same picker as a sheet.
        if let source = merging {
            mergePicker(source, fills: fills)
        } else {
            browser
        }
        #else
        browser
        #endif
    }

    private func mergePicker(_ source: Voice, fills: Bool) -> some View {
        MergeVoicePicker(source: source, voices: people.voices,
                         suggested: people.sameAs(source), fills: fills,
                         maxListHeight: mergeListCap,
                         onMerge: { target in
                             people.merge(source, into: target)
                             merging = nil
                         },
                         onCancel: { merging = nil })
            .id(source.id)
    }

    private var browser: some View {
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
                if showsSearch { searchField }
                scrollingList { lists }
                learnedFooter
            }
        }
    }

    /// Search once the library is long enough to need it, and always in the
    /// window, where there is room and the list is what the window is for.
    /// Unnamed voices count too: "Voice 14" is how you find one of many.
    private var showsSearch: Bool {
        fills || people.voices.count > PeoplePaneLayout.uncappedRows || people.worthAsking.count > 3
    }

    private var searching: Bool { !Names.normalise(query).isEmpty }

    private func shown(_ voices: [Voice]) -> [Voice] {
        voices.filter { MergeCandidates.matches($0, query: query) }
    }

    /// Rows actually on screen. Hidden voices count as one header until opened,
    /// so a drawer of dismissed strangers does not force the whole tab to scroll.
    private var openRowCount: Int {
        let hiddenRows = people.hidden.isEmpty ? 0
            : ((showHidden || searching) ? shown(people.hidden).count : 1)
        return shown(people.worthAsking).count + shown(people.heardOnce).count
            + shown(people.named).count + hiddenRows
    }

    private var capsList: Bool {
        // Snapshots draw the whole tab at its own height. A fixed cap here
        // would be a tall empty well in the README image.
        #if os(macOS)
        if Snapshots.rendering { return false }
        #endif
        return openRowCount > PeoplePaneLayout.uncappedRows || shown(people.worthAsking).count > 3
    }

    private var searchField: some View {
        TextField("Search people", text: $query)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .ataFont(11)
    }

    private var lists: some View {
        let asking = shown(people.worthAsking)
        let once = shown(people.heardOnce)
        let named = shown(people.named)
        let hidden = shown(people.hidden)
        return VStack(alignment: .leading, spacing: 10) {
            if searching, asking.isEmpty, once.isEmpty, named.isEmpty, hidden.isEmpty {
                Text("No one matches")
                    .ataFont(11).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            if !asking.isEmpty {
                section(L("Who's this?"), count: sectionCount(asking.count),
                        footnote: L("Heard in several meetings. Play a sample, then type a name.")) {
                    ForEach(asking) { row($0, asking: true) }
                }
            }
            if !once.isEmpty {
                section(L("Heard once"), count: sectionCount(once.count),
                        footnote: L("Ata asks for a name once it has heard a voice in two meetings. You can name one now anyway — or say it's you.")) {
                    ForEach(once) { row($0, asking: true) }
                }
            }
            if !named.isEmpty {
                section(L("People"), count: sectionCount(named.count), footnote: nil) {
                    LazyVStack(spacing: 2) {
                        ForEach(named) { row($0, asking: false) }
                    }
                }
            }
            hiddenSection(hidden)
        }
    }

    /// A count is only useful once the list is long. A handful of people
    /// already shows every row, and a number beside the title is noise.
    private func sectionCount(_ count: Int) -> Int? {
        (people.voices.count > PeoplePaneLayout.uncappedRows || searching) ? count : nil
    }

    @ViewBuilder private func hiddenSection(_ hidden: [Voice]) -> some View {
        if !hidden.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { showHidden.toggle() } label: {
                    HStack(spacing: 5) {
                        Text(L("Hidden voices").uppercased())
                            .ataFont(9, weight: .semibold).foregroundStyle(.secondary)
                        Text(verbatim: "\(hidden.count)")
                            .ataFont(9, weight: .medium).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Image(systemName: (showHidden || searching) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Hidden voices"))
                if showHidden || searching {
                    Text("Not asked about, or left out of every transcript.")
                        .ataFont(10).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(hidden) { HiddenVoiceRow(voice: $0, onMerge: mergeAction(for: $0)) }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
                }
            }
        }
    }

    private func row(_ voice: Voice, asking: Bool) -> some View {
        VoiceRow(voice: voice, asking: asking, onMerge: mergeAction(for: voice))
    }

    /// Nil when there is nobody to merge into, so the control is not offered
    /// for a library of one.
    private func mergeAction(for voice: Voice) -> (() -> Void)? {
        guard people.voices.contains(where: { $0.id != voice.id && ($0.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) }) else {
            return nil
        }
        return { merging = voice }
    }

    private var learnedFooter: some View {
        HStack {
            Text(Self.learnedLine(people.voices.count))
                .ataFont(10).foregroundStyle(.secondary)
            Spacer()
            Button(confirmForgetAll ? L("Delete all?") : L("Forget all")) {
                if confirmForgetAll { people.forgetAll(); confirmForgetAll = false } else {
                    confirmForgetAll = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmForgetAll = false }
                }
            }
            .buttonStyle(.plain)
            .ataFont(10, weight: .medium)
            .foregroundStyle(confirmForgetAll ? .red : .secondary)
        }
    }

    /// The menu list's height. Snapshots draw the whole tab, uncapped, so the
    /// README shows every row rather than a scroll cut off mid-list.
    private var menuListCap: CGFloat {
        #if os(macOS)
        if Snapshots.rendering { return 4_000 }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return PeoplePaneLayout.listCap(screenHeight: screen, reserve: PeoplePaneLayout.menuReserve)
        #else
        return 800
        #endif
    }

    private var mergeListCap: CGFloat {
        #if os(macOS)
        if Snapshots.rendering { return 4_000 }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 900
        return PeoplePaneLayout.listCap(screenHeight: screen, reserve: PeoplePaneLayout.mergeReserve)
        #else
        return 800
        #endif
    }

    /// Scroll only once the rows would push the rest of the panel off the
    /// screen. A short library keeps its own height, which is what the menu
    /// is sized to.
    @ViewBuilder private func scrollingList<V: View>(@ViewBuilder content: () -> V) -> some View {
        #if os(iOS)
        content()
        #else
        if fills {
            ScrollView { content() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if capsList {
            ScrollView { content() }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: menuListCap)
                .scrollIndicators(.visible, axes: .vertical)
        } else {
            content()
        }
        #endif
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

    private func section<C: View>(_ title: String, count: Int? = nil, footnote: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(title.uppercased()).ataFont(9, weight: .semibold).foregroundStyle(.secondary)
                if let count {
                    Text(verbatim: "\(count)")
                        .ataFont(9, weight: .medium).foregroundStyle(.secondary)
                }
            }
            if let footnote {
                Text(footnote).ataFont(10).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) { content() }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

/// Searchable list of people a voice can be folded into. One tap selects,
/// Merge confirms: the list can be long, and the tap deletes the voice.
struct MergeVoicePicker: View {
    let source: Voice
    let voices: [Voice]
    let suggested: [Voice]
    var fills: Bool
    var maxListHeight: CGFloat
    let onMerge: (Voice) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var chosen: UUID?
    @FocusState private var focused: Bool

    private var arranged: MergeCandidates.Result {
        MergeCandidates.arrange(source: source, voices: voices, suggested: suggested, query: query)
    }

    var body: some View {
        let arranged = arranged
        VStack(alignment: .leading, spacing: 8) {
            header
            TextField("Search people", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .ataFont(11)
                .focused($focused)
                .onSubmit { confirm(arranged) }
            if arranged.isEmpty {
                Text("No one matches")
                    .ataFont(11).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                candidateList(arranged)
            }
            if let target = selected(in: arranged) {
                confirmBar(target)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
        .onAppear { focused = true }
        .onExitCommand { onCancel() }
        .onChange(of: query) { _, _ in
            if let chosen, !MergeCandidates.arrange(source: source, voices: voices,
                                                     suggested: suggested, query: query).contains(chosen) {
                self.chosen = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 6) {
            Button { onCancel() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L("Back"))
            .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 2) {
                Text("Merge with…").ataFont(13, weight: .semibold)
                Text(L("Pick who %@ really is. Transcripts use that name.", source.displayName))
                    .ataFont(10).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func candidateList(_ arranged: MergeCandidates.Result) -> some View {
        let rows = VStack(alignment: .leading, spacing: 8) {
            if !arranged.suggested.isEmpty {
                group(L("Suggested"), arranged.suggested, suggested: true)
            }
            if !arranged.others.isEmpty {
                group(L("People"), arranged.others, suggested: false)
            }
        }
        scrolling(rowCount: arranged.count) { rows }
    }

    private func group(_ title: String, _ voices: [Voice], suggested: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).ataFont(9, weight: .semibold).foregroundStyle(.secondary)
            ForEach(voices) { voice in
                candidate(voice, suggested: suggested)
            }
        }
    }

    private func candidate(_ voice: Voice, suggested: Bool) -> some View {
        let on = chosen == voice.id
        return Button { chosen = voice.id } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(voice.name ?? voice.displayName)
                        .ataFont(12, weight: .semibold).lineLimit(1)
                    Text(detail(voice, suggested: suggested))
                        .ataFont(10).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func detail(_ voice: Voice, suggested: Bool) -> String {
        if voice.isMe { return L("You") }
        if suggested { return L("Same meetings · %d", voice.meetings) }
        return L("%d meetings", voice.meetings)
    }

    private func confirmBar(_ target: Voice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("%@ becomes %@.", source.displayName, target.name ?? target.displayName))
                .ataFont(11)
                .fixedSize(horizontal: false, vertical: true)
            Button("Merge") { onMerge(target) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func selected(in arranged: MergeCandidates.Result) -> Voice? {
        guard let chosen else { return nil }
        return (arranged.suggested + arranged.others).first { $0.id == chosen }
    }

    /// Return merges the selection, or the only name left after a search.
    /// Anything wider than that waits for an explicit tap: merging deletes a voice.
    private func confirm(_ arranged: MergeCandidates.Result) {
        if let target = selected(in: arranged) {
            onMerge(target)
        } else if arranged.count == 1, let only = arranged.suggested.first ?? arranged.others.first {
            onMerge(only)
        }
    }

    @ViewBuilder private func scrolling<V: View>(rowCount: Int, @ViewBuilder content: () -> V) -> some View {
        if fills {
            ScrollView { content() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if rowCount > PeoplePaneLayout.uncappedRows {
            ScrollView { content() }
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: maxListHeight)
                .scrollIndicators(.visible, axes: .vertical)
        } else {
            content()
        }
    }
}

private struct VoiceRow: View {
    @StateObject private var people = PeopleModel.shared
    let voice: Voice
    let asking: Bool
    var onMerge: (() -> Void)? = nil
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
                    Text(voice.displayName).ataFont(12, weight: .semibold).lineLimit(1)
                } else if !editing {
                    Text(voice.name ?? "").ataFont(12, weight: .semibold).lineLimit(1)
                }
                if asking || editing {
                    TextField(L("Name"), text: $name, prompt: Text(L("Type their name…")))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .ataFont(11)
                        .focused($focused)
                        .onSubmit { save() }
                        .onExitCommand { editing = false; name = "" }
                }
                if asking { suggestions }
                Text(L("%d meetings · heard %@", voice.meetings,
                       voice.lastSeen.formatted(.relative(presentation: .named))))
                    .ataFont(10).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if (asking || editing) && !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(L("Save")) { save() }.controlSize(.small)
            } else if asking {
                if onMerge != nil { mergeButton }
                Button { people.dismiss(voice) } label: {
                    Image(systemName: "xmark").ataFont(10, weight: .bold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Don't ask about this voice"))
                .accessibilityLabel(L("Don't ask about this voice"))
            } else if onMerge != nil {
                mergeButton
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

    private var mergeButton: some View {
        Button { onMerge?() } label: {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L("Merge with…"))
        .accessibilityLabel(L("Merge with…"))
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
        if let onMerge {
            Button(L("Merge with…")) { onMerge() }
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
                            .ataFont(9).foregroundStyle(.secondary).lineLimit(1)
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
                .accessibilityLabel(L("Play a sample"))

                TextField(L("Your name"), text: $myName, prompt: Text(L("Me")))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .ataFont(11)
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
                    .ataFont(10).foregroundStyle(.secondary).lineLimit(1)
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
            .padding(.horizontal, 4)
        case .learning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Learning your voice…").ataFont(10).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 4) {
                Text(why).ataFont(10).foregroundStyle(.orange)
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
    var onMerge: (() -> Void)? = nil

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
                Text(voice.displayName).ataFont(12, weight: .medium).lineLimit(1)
                Text(voice.isExcluded ? L("Left out of transcripts") : L("Not asked about"))
                    .ataFont(10).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if onMerge != nil {
                Button { onMerge?() } label: {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L("Merge with…"))
                .accessibilityLabel(L("Merge with…"))
            }
            Button(voice.isExcluded ? L("Put back") : L("Ask again")) {
                if voice.isExcluded { people.setExcluded(voice, false) } else { people.dismiss(voice, false) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .contextMenu {
            if let onMerge {
                Button(L("Merge with…")) { onMerge() }
            }
            if !voice.isExcluded {
                Button(L("Leave out of transcripts")) { people.setExcluded(voice, true) }
            }
            if onMerge != nil || !voice.isExcluded { Divider() }
            Button(L("Forget this voice"), role: .destructive) { people.forget(voice) }
        }
    }
}
