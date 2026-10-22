import AppKit
import UserNotifications

/// Actionable notifications: "Record" when a meeting is detected, "Stop" while recording,
/// "Open" when a transcript is ready, and "Update" when a new release is out.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    private enum ID {
        static let detected = "MEETING_DETECTED"
        static let recording = "RECORDING"
        static let ready = "TRANSCRIPT_READY"
        static let record = "RECORD"
        static let stop = "STOP"
        static let open = "OPEN"
        static let update = "UPDATE_AVAILABLE"
        static let install = "INSTALL"
    }

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        let record = UNNotificationAction(identifier: ID.record, title: L("Record"), options: [])
        let stop = UNNotificationAction(identifier: ID.stop, title: L("Stop and transcribe"), options: [])
        let open = UNNotificationAction(identifier: ID.open, title: L("Open"), options: [.foreground])
        let install = UNNotificationAction(identifier: ID.install, title: L("Update"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ID.detected, actions: [record], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ID.recording, actions: [stop], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ID.ready, actions: [open], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ID.update, actions: [install], intentIdentifiers: [], options: []),
        ])
    }

    func meetingDetected(app: String) {
        post(id: "detected", category: ID.detected, title: L("Meeting in %@", app),
             body: L("Record and transcribe this meeting?"), info: ["app": app])
    }

    func recordingStarted(app: String?) {
        post(id: "recording", category: ID.recording, title: L("Recording") + (app.map { " · \($0)" } ?? ""),
             body: L("Ata is recording your microphone and your Mac's audio."), info: [:], sound: false)
    }

    func transcriptReady(_ m: Meeting) {
        clear("recording")
        post(id: "ready-\(m.id)", category: ID.ready, title: L("Transcript ready"),
             body: "\(m.title) · \(m.subtitle)", info: ["path": m.transcriptURL.path, "meeting": m.id])
    }

    func transcriptFailed(_ m: Meeting, error: String) {
        post(id: "failed-\(m.id)", category: "", title: L("Transcription failed"),
             body: L("%@: %@. The audio is safe — you can try again from Ata.", m.title, error), info: [:])
    }

    func updateAvailable(version: String) {
        post(id: "update", category: ID.update, title: L("Ata %@ is available", version),
             body: L("Install it from the Ata menu, or tap Update."), info: [:], sound: false)
    }

    func clear(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func post(id: String, category: String, title: String, body: String,
                      info: [String: String], sound: Bool = true) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = category
        c.userInfo = info
        if sound { c.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier
        let path = info["path"] as? String
        let meetingID = info["meeting"] as? String
        let app = info["app"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let store = AppStore.shared
                switch (category, action) {
                case (ID.detected, ID.record), (ID.detected, UNNotificationDefaultActionIdentifier):
                    store.startRecording(app: app)
                case (ID.recording, ID.stop):
                    store.stopRecording()
                case (ID.update, ID.install), (ID.update, UNNotificationDefaultActionIdentifier):
                    Updater.shared.installUpdate()
                case (ID.ready, _):
                    guard action != UNNotificationDismissActionIdentifier else { break }
                    if let meetingID {
                        WindowManager.shared.showMeeting(meetingID)
                    } else if let path {
                        // Delivered by Ata 2.3 or earlier, before notifications named the meeting.
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                default:
                    break
                }
            }
            completionHandler()
        }
    }
}
