import AppIntents
import Foundation

// Compiled into both the app and the widget extension, because the Live Activity's
// buttons and the Control Center control name these intents. They always run in
// the app's process (that is what the audio-recording and Live Activity intent
// kinds are for), which is the only target built with ATA_APP.

/// Starts recording from the Action button, Siri, Shortcuts or the control.
///
/// An audio-recording intent may turn the microphone on while Ata is in the
/// background, provided a Live Activity shows the recording; starting a
/// recording always starts one.
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record a conversation"
    static let description = IntentDescription("Starts recording with Ata. It keeps going with the screen locked until you stop it.")

    /// Background when the recording can start, so a Control or Siri does not
    /// pull Ata forward for a recording that is already on the lock screen.
    /// `.foreground(.dynamic)` is what lets `continueInForeground` open Ata
    /// only when the recording cannot start.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    func perform() async throws -> some IntentResult {
        #if ATA_APP
        do {
            try await PhoneStore.shared.startFromIntent()
        } catch {
            await presentBlock(error)
            throw error
        }
        #endif
        return .result()
    }

    #if ATA_APP
    /// Brings Ata forward for the free limit or a denied microphone, then shows
    /// that reason. The error is rethrown so Siri still speaks it.
    private func presentBlock(_ error: Error) async {
        guard PhoneStore.shouldOpenForBlockedStart(error) else { return }
        let active = await PhoneStore.shared.isApplicationActive
        var becomingForeground = false
        if !active {
            do {
                try await continueInForeground(alwaysConfirm: false)
                becomingForeground = true
            } catch {
                becomingForeground = false
            }
        }
        await PhoneStore.shared.presentBlockedStart(error, appIsActive: active,
                                                    becomingForeground: becomingForeground)
    }
    #endif
}

/// Stops the recording; the transcript follows.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop recording"
    static let description = IntentDescription("Stops the recording and queues it to be transcribed.")

    func perform() async throws -> some IntentResult {
        #if ATA_APP
        await PhoneStore.shared.stopFromIntent()
        #endif
        return .result()
    }
}

/// Marks the current moment of the recording, to find it again later.
struct BookmarkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark this moment"
    static let description = IntentDescription("Marks this moment of the recording so you can find it later.")

    func perform() async throws -> some IntentResult {
        #if ATA_APP
        await PhoneStore.shared.bookmarkFromIntent()
        #endif
        return .result()
    }
}
