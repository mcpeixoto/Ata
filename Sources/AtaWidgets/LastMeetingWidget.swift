import AppIntents
import SwiftUI
import WidgetKit

/// The last meeting and a record button, on the home screen; a record button on
/// the lock screen.
struct LastMeetingWidget: Widget {
    static let kind = "ai.interactive.ata.last-meeting"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: Provider()) { entry in
            LastMeetingView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Ata")
        .description("Your last meeting, and a button to record the next one.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }

    struct Entry: TimelineEntry {
        let date: Date
        let snapshot: WidgetSnapshot
    }

    /// The app writes the snapshot and reloads the timeline when it changes, so
    /// one entry that never expires is enough.
    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(date: Date(), snapshot: WidgetSnapshot())
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry(date: Date(), snapshot: WidgetSnapshot.load()))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: Date(), snapshot: WidgetSnapshot.load())], policy: .never))
        }
    }
}

private struct LastMeetingView: View {
    let entry: LastMeetingWidget.Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: StartRecordingIntent()) {
                Image(systemName: entry.snapshot.recordingSince == nil ? "mic.fill" : "waveform")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .widgetAccentable()
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let since = entry.snapshot.recordingSince {
                Label("Recording", systemImage: "record.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text(since, style: .timer)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            } else if let title = entry.snapshot.lastTitle, let started = entry.snapshot.lastStartedAt {
                Text("Last meeting")
                    .font(.caption).foregroundStyle(.secondary)
                Text(title).font(.headline).lineLimit(2)
                Text(started, style: .relative)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No meetings yet")
                    .font(.headline)
            }
            Spacer(minLength: 0)
            if entry.snapshot.recordingSince == nil {
                Button(intent: StartRecordingIntent()) {
                    Label("Record", systemImage: "mic.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
