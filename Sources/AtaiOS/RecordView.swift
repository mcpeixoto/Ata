import SwiftUI

/// The first tab: one big button, the time, how loud it is, and what kind of
/// conversation this is.
struct RecordView: View {
    @EnvironmentObject var store: PhoneStore
    @ObservedObject private var pro = ProStore.shared

    var body: some View {
        NavigationStack {
            // Anchored to the top, so nothing moves when a recording starts and
            // there is no empty band above the timer. At the largest text sizes
            // it scrolls instead of clipping.
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
            .navigationTitle("Ata")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var content: some View {
        VStack(spacing: 24) {
            status

            Text(verbatim: Transcriber.timestamp(Int(store.elapsed * 1000)))
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(store.isRecording ? Color.primary : Color.secondary)
                .contentTransition(.numericText())

            LevelMeter(level: store.level, tint: Theme.meTint)
                .frame(maxWidth: 240)
                .opacity(store.isRecording ? 1 : 0.4)

            recordButton

            if store.phase == .interrupted {
                interrupted
            } else if store.isRecording {
                bookmarkButton
            } else {
                modePicker
            }

            messages

            Spacer(minLength: 12)

            if !pro.isPro && !store.isRecording { freeMeetings }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
    }

    /// What is happening, in words: the white timer alone said too little. Idle
    /// keeps the line's height so the timer doesn't jump when recording starts.
    private var status: some View {
        let recording = store.phase == .recording
        let paused = store.phase == .interrupted
        return HStack(spacing: 6) {
            Circle()
                .fill(paused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
            Text(paused ? L("Paused") : L("Recording"))
                .fontWeight(.semibold)
            Text(verbatim: "·").foregroundStyle(.secondary)
            Label(store.mode.title, systemImage: store.mode.symbol)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(paused ? Color.orange : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .opacity(recording || paused ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!(recording || paused))
    }

    private var recordButton: some View {
        Button { store.toggleRecording() } label: {
            ZStack {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 120, height: 120)
                    .shadow(color: .red.opacity(0.35), radius: 16, y: 6)
                if store.isRecording {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white)
                        .frame(width: 40, height: 40)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.phase == .starting || store.phase == .stopping)
        .accessibilityLabel(store.isRecording ? L("Stop recording") : L("Record a conversation"))
        .sensoryFeedback(.impact, trigger: store.isRecording)
    }

    private var modePicker: some View {
        VStack(spacing: 8) {
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
        VStack(spacing: 6) {
            Button { store.addBookmark() } label: {
                Label("Mark this moment", systemImage: "bookmark.fill")
            }
            .buttonStyle(.bordered)
            if !store.bookmarks.isEmpty {
                Text(L("Moments marked: %d", store.bookmarks.count))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var interrupted: some View {
        VStack(spacing: 8) {
            Label("Paused: another app is using the microphone.", systemImage: "pause.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Button("Resume") { store.resumeRecording() }
                .buttonStyle(.borderedProminent)
        }
    }

    /// Ata Pro lifts this; see `FreeQuota`.
    private var freeMeetings: some View {
        let left = FreeQuota.remaining(used: store.freeUsed)
        return Button { PhoneNavigation.shared.showPaywall() } label: {
            Text(left == 1 ? L("1 free meeting left this month") : L("%d free meetings left this month", left))
                .font(.footnote)
                .foregroundStyle(left == 0 ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var messages: some View {
        if let warning = store.warning {
            Text(warning).font(.footnote).foregroundStyle(.orange)
        }
        if let error = store.lastError {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
