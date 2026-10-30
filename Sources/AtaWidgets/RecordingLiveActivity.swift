import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The recording on the lock screen and in the Dynamic Island: the time, and
/// Bookmark and Stop without unlocking.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecording(attributes: context.attributes, state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.mode.title, systemImage: context.attributes.mode.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingTimer(state: context.state)
                        .font(.title3.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingButtons(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "waveform")
                    .foregroundStyle(.red)
            } compactTrailing: {
                RecordingTimer(state: context.state)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct LockScreenRecording: View {
    let attributes: RecordingActivityAttributes
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.isPaused ? L("Paused") : L("Recording"),
                      systemImage: state.isPaused ? "pause.circle.fill" : "record.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.isPaused ? Color.orange : Color.red)
                Spacer()
                RecordingTimer(state: state)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text(attributes.mode.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            RecordingButtons(state: state)
        }
    }
}

/// Counts up while recording; stands still at the recorded length while paused.
private struct RecordingTimer: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Group {
            if state.isPaused {
                Text(verbatim: Self.clock(state.pausedSeconds))
            } else {
                Text(state.timerStart, style: .timer)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct RecordingButtons: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: BookmarkIntent()) {
                Label(state.bookmarks > 0 ? L("Mark (%d)", state.bookmarks) : L("Mark"),
                      systemImage: "bookmark.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.blue)
            Button(intent: StopRecordingIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.red)
        }
        .font(.subheadline.weight(.semibold))
    }
}
