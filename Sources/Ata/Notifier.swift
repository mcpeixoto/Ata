import AppKit
import UserNotifications

/// Notificações com ações: "Gravar" quando é detetada uma meeting, "Parar" durante a gravação,
/// e "Abrir" quando a transcrição fica pronta.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    private enum ID {
        static let detected = "MEETING_DETECTED"
        static let recording = "RECORDING"
        static let ready = "TRANSCRIPT_READY"
        static let record = "RECORD"
        static let stop = "STOP"
        static let open = "OPEN"
    }

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        let record = UNNotificationAction(identifier: ID.record, title: "Gravar", options: [])
        let stop = UNNotificationAction(identifier: ID.stop, title: "Parar e transcrever", options: [])
        let open = UNNotificationAction(identifier: ID.open, title: "Abrir", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ID.detected, actions: [record], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ID.recording, actions: [stop], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: ID.ready, actions: [open], intentIdentifiers: [], options: []),
        ])
    }

    func meetingDetected(app: String) {
        post(id: "detected", category: ID.detected, title: "Meeting no \(app)",
             body: "Queres gravar e transcrever esta meeting?", info: ["app": app])
    }

    func recordingStarted(app: String?) {
        post(id: "recording", category: ID.recording, title: "A gravar\(app.map { " · \($0)" } ?? "")",
             body: "A Ata está a gravar o teu micro e o som do Mac.", info: [:], sound: false)
    }

    func transcriptReady(_ m: Meeting) {
        clear("recording")
        post(id: "ready-\(m.id)", category: ID.ready, title: "Transcrição pronta",
             body: "\(m.title) · \(m.subtitle)", info: ["path": m.transcriptURL.path])
    }

    func transcriptFailed(_ m: Meeting, error: String) {
        post(id: "failed-\(m.id)", category: "", title: "A transcrição falhou",
             body: "\(m.title): \(error). O áudio está guardado — podes tentar de novo na Ata.", info: [:])
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
        let app = info["app"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let store = AppStore.shared
                switch (category, action) {
                case (ID.detected, ID.record), (ID.detected, UNNotificationDefaultActionIdentifier):
                    store.startRecording(app: app)
                case (ID.recording, ID.stop):
                    store.stopRecording()
                case (ID.ready, _):
                    if let path, action != UNNotificationDismissActionIdentifier {
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
