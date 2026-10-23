import AppIntents
import SwiftUI
import WidgetKit

/// "Record with Ata" for Control Center, the lock screen and the Action button.
struct RecordControl: ControlWidget {
    static let kind = "ai.interactive.ata.record"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Record with Ata", systemImage: "mic.fill")
            }
        }
        .displayName("Record with Ata")
        .description("Starts recording a conversation, even from the lock screen.")
    }
}
