import SwiftUI

/// The first tab: one big button, the time, how loud it is, and what kind of
/// conversation this is.
struct RecordView: View {
    @EnvironmentObject var store: PhoneStore

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 12)

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
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .navigationTitle("Ata")
            .navigationBarTitleDisplayMode(.inline)
        }
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
                Label("Bookmark this moment", systemImage: "bookmark.fill")
            }
            .buttonStyle(.bordered)
            if !store.bookmarks.isEmpty {
                Text(L("Bookmarks: %d", store.bookmarks.count))
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
