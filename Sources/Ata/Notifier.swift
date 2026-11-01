import Foundation
import UserNotifications

/// Actionable notifications: "Record" when a meeting is detected, "Stop" while recording,
/// "Open" when a transcript is ready, and "Update" when a new release is out.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    private enum ID {
        static let detected = "MEETING_DETECTED"
        static let soon = "MEETING_SOON"
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
            UNNotificationCategory(identifier: ID.soon, actions: [record], intentIdentifiers: [], options: []),
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
                      info: [String: String], sound: Bool = true,
                      trigger: UNNotificationTrigger? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.categoryIdentifier = category
        c.userInfo = info
        if sound { c.sound = .default }
        center.add(UNNotificationRequest(identifier: id, content: c, trigger: trigger)) { _ in }
    }

    // MARK: Meetings on the calendar

    /// Makes the pending prompts match `wanted`, keyed by occurrence.
    ///
    /// Adding a request whose identifier already exists replaces it, so one
    /// meeting can only ever have one prompt — and anything no longer on the
    /// calendar is withdrawn. Ata's first scheduled notifications: everything
    /// else it posts fires immediately.
    func scheduleMeetings(_ wanted: [String: (event: MeetingEvent, fire: Date)], leadMinutes: Int) {
        center.getPendingNotificationRequests { pending in
            let stale = pending.filter { $0.content.categoryIdentifier == ID.soon && wanted[$0.identifier] == nil }
            Task { @MainActor in
                self.center.removePendingNotificationRequests(withIdentifiers: stale.map(\.identifier))
                for (key, due) in wanted { self.scheduleMeeting(due.event, key: key, at: due.fire,
                                                                leadMinutes: leadMinutes) }
            }
        }
    }

    private func scheduleMeeting(_ event: MeetingEvent, key: String, at fire: Date, leadMinutes: Int) {
        // Date components in the current zone, so a prompt scheduled before a
        // flight and fired after it is not an hour out.
        let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
        let title = leadMinutes <= 1
            ? L("%@ starts in a minute", event.title)
            : L("%@ starts in %d minutes", event.title, leadMinutes)
        post(id: key, category: ID.soon, title: title, body: L("Record and transcribe it?"),
             info: ["event": MeetingEventCoding.json(event) ?? ""],
             trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
    }

    /// Withdraws every scheduled meeting prompt — the feature was turned off,
    /// or access was taken away.
    func clearScheduledMeetings() {
        center.getPendingNotificationRequests { pending in
            let ours = pending.filter { $0.content.categoryIdentifier == ID.soon }.map(\.identifier)
            Task { @MainActor in self.center.removePendingNotificationRequests(withIdentifiers: ours) }
        }
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
                #if os(macOS)
                // The calendar prompt is the Mac's: the iPhone does not watch a
                // calendar, and its store has no such entry point.
                case (ID.soon, ID.record):
                    store.startRecording(event: MeetingEventCoding.event(info["event"] as? String))
                case (ID.soon, UNNotificationDefaultActionIdentifier),
                     (ID.detected, UNNotificationDefaultActionIdentifier):
                    // Clicking the banner to look at it must not start recording people.
                    WindowManager.shared.showMain()
                #endif
                case (ID.detected, ID.record):
                    store.startRecording(app: app)
                case (ID.recording, ID.stop):
                    store.stopRecording()
                #if os(macOS)
                case (ID.update, ID.install), (ID.update, UNNotificationDefaultActionIdentifier):
                    Updater.shared.installUpdate()
                #endif
                case (ID.ready, _):
                    guard action != UNNotificationDismissActionIdentifier else { break }
                    if let meetingID {
                        WindowManager.shared.showMeeting(meetingID)
                    } else if let path {
                        // Delivered by Ata 2.3 or earlier, before notifications named the meeting.
                        Platform.actions.open(URL(fileURLWithPath: path))
                    }
                default:
                    break
                }
            }
            completionHandler()
        }
    }
}
