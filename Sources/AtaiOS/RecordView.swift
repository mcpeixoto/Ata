import SwiftUI

/// The first tab. Idle is the record button, a little above the middle, with
/// the mode and the free-meetings line in one card. While recording, the timer
/// leads and the same button stops it.
struct RecordView: View {
    @EnvironmentObject var store: PhoneStore
    @ObservedObject private var live = PhoneLive.shared
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The Mac popover uses 30 pt rounded semibold. On the phone the same
    /// face starts at 56 and grows with the Large Title text size.
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize = 56

    var body: some View {
        NavigationStack {
            // The column is centred while it fits. Past that, the same column
            // scrolls, so the largest text sizes are never clipped.
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if store.isRecording {
                            recording
                        } else {
                            idle
                        }
                    }
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.l)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .navigationTitle("Ata")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { store.clearMicrophoneDenialIfGranted() }
        }
    }

    /// 00:00 is not shown. Nothing is being timed yet: the button and the mode
    /// card already say this meeting has not started, and a spare zero would
    /// sit on its own the way the free-meetings line used to.
    private var idle: some View {
        VStack(spacing: Theme.Space.xl) {
            recordButton
            idleCard
        }
        .frame(maxWidth: .infinity)
    }

    private var recording: some View {
        VStack(spacing: Theme.Space.xl) {
            Text(verbatim: Transcriber.timestamp(Int(live.elapsed * 1000)))
                .font(.system(size: timerSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(paused ? Theme.warning : Color.primary)
                .contentTransition(.numericText())

            status

            LevelMeter(level: live.level, tint: paused ? Theme.warning : Theme.recordingSolid)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            recordButton

            if paused {
                interrupted
            } else {
                bookmarkButton
            }

            messages
        }
        .frame(maxWidth: .infinity)
    }

    private var paused: Bool { store.phase == .interrupted }

    private var idleCard: some View {
        Card(padding: Theme.Space.l) {
            VStack(spacing: Theme.Space.m) {
                modePicker
                messages
                if !pro.isPro { freeMeetings }
            }
        }
    }

    private var status: some View {
        ViewThatFits(in: .horizontal) {
            statusLine
            VStack(spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.s) {
                    statusDot
                    Text(paused ? L("Paused") : L("Recording"))
                        .fontWeight(.semibold)
                }
                Label(store.mode.title, systemImage: store.mode.symbol)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(paused ? Theme.warning : Theme.recordingSolid)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .accessibilityElement(children: .combine)
    }

    private var statusLine: some View {
        HStack(spacing: Theme.Space.s) {
            statusDot
            Text(paused ? L("Paused") : L("Recording"))
                .fontWeight(.semibold)
            Text(verbatim: "·").foregroundStyle(.secondary)
            Label(store.mode.title, systemImage: store.mode.symbol)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var statusDot: some View {
        Circle()
            .fill(paused ? Theme.warning : Theme.recordingSolid)
            .frame(width: 8, height: 8)
    }

    private var recordButton: some View {
        HeroRecordButton(size: 120, state: recordState) { store.toggleRecording() }
            .disabled(store.phase == .starting || store.phase == .stopping)
            .accessibilityLabel(store.isRecording ? L("Stop recording") : L("Record a conversation"))
            .sensoryFeedback(.impact, trigger: store.isRecording)
    }

    /// Starting and stopping keep the microphone glyph and skip the idle ring.
    /// Recording, including a pause, is the white stop mark.
    private var recordState: HeroRecordButton.Phase {
        if store.phase == .starting || store.phase == .stopping { return .busy }
        if store.isRecording { return .recording }
        return .idle
    }

    private var modePicker: some View {
        VStack(spacing: Theme.Space.s) {
            Picker("Mode", selection: $store.mode) {
                ForEach(RecordingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(store.mode == .inPerson
                 ? L("For a conversation in the room. Put the iPhone between you.")
                 : L("For a call on another phone or computer's speaker, with this iPhone next to it."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bookmarkButton: some View {
        VStack(spacing: Theme.Space.s) {
            Button { store.addBookmark() } label: {
                Label("Mark this moment", systemImage: "bookmark.fill")
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.secondary)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
            if !store.bookmarks.isEmpty {
                Text(L("Moments marked: %d", store.bookmarks.count))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var interrupted: some View {
        VStack(spacing: Theme.Space.s) {
            Label {
                Text("Paused: another app is using the microphone.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "pause.circle.fill")
            }
            .font(.subheadline)
            .foregroundStyle(Theme.warning)
            Button("Resume") { store.resumeRecording() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Ata Pro lifts this; see `FreeQuota`.
    private var freeMeetings: some View {
        let left = FreeQuota.remaining(used: store.freeUsed)
        return Button { PhoneNavigation.shared.showPaywall() } label: {
            Text(left == 1 ? L("1 free minute left this month") : L("%d free minutes left this month", left))
                .font(.footnote)
                .foregroundStyle(left == 0 ? Theme.warning : Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var messages: some View {
        if let warning = store.warning {
            Text(warning)
                .font(.footnote)
                .foregroundStyle(Theme.warning)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = store.lastError {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.footnote)
            .foregroundStyle(Theme.danger)
        }
    }
}
