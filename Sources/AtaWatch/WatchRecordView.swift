import SwiftUI

/// The one screen: where the recording happens, the time, a big record and
/// stop button, and a bookmark button while recording.
struct WatchRecordView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                place
                timer
                recordButton
                if model.isRecording {
                    if model.isPaused { paused }
                    bookmarkButton
                }
                notices
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
        }
    }

    private var place: some View {
        Group {
            if model.isRecordingHere {
                Text("Recording on this Apple Watch")
            } else if model.isRecordingOnPhone {
                Text("Recording on your iPhone")
            } else if model.reachable {
                Text("Records on your iPhone")
            } else {
                Text("Records on this Apple Watch")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    private var timer: some View {
        let clock = model.clock
        return Group {
            if let start = clock.timerStart {
                Text(start, style: .timer)
            } else {
                Text(verbatim: WatchFormat.clock(clock.elapsed(at: Date())))
            }
        }
        .font(.system(size: 40, weight: .light, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(model.isRecording ? Color.primary : Color.secondary)
    }

    private var recordButton: some View {
        Button { model.recordTapped() } label: {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .frame(width: 84, height: 84)
                if model.isBusy {
                    ProgressView()
                        .tint(.white)
                } else if model.isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityLabel(model.isRecording ? L("Stop recording") : L("Record a conversation"))
    }

    private var paused: some View {
        VStack(spacing: 6) {
            Label("Paused", systemImage: "pause.circle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            // Here or on the iPhone: a call can end without handing the microphone back to either.
            Button("Resume") { model.resumeTapped() }
                .disabled(model.isBusy)
        }
    }

    private var bookmarkButton: some View {
        VStack(spacing: 4) {
            Button { model.bookmarkTapped() } label: {
                Label("Bookmark", systemImage: "bookmark.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(model.isBusy)
            if model.bookmarkCount > 0 {
                Text(L("Bookmarks: %d", model.bookmarkCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        switch model.notice {
        case .openPhone?:
            offerToRecordHere(Text("Open Ata on your iPhone to record there."))
        case .noAnswer?:
            offerToRecordHere(Text("Your iPhone did not answer."))
        case .phoneMicrophone?:
            offerToRecordHere(Text("Allow Ata on your iPhone to use the microphone."))
        case .failed(let text)?:
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        case nil:
            EmptyView()
        }
        if model.phoneMayBeRecording {
            Text("Ata may still be recording on your iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        if model.unsent > 0 && !model.isRecordingHere {
            Text(L("Recordings waiting for your iPhone: %d", model.unsent))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func offerToRecordHere(_ message: Text) -> some View {
        VStack(spacing: 6) {
            message
                .font(.footnote)
                .multilineTextAlignment(.center)
            Button("Record on this Apple Watch") { model.recordHere() }
        }
    }
}
