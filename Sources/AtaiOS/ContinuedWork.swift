import BackgroundTasks
import Foundation

/// Keeps a transcription going after you leave Ata, with the system's own
/// progress indicator: iOS 26's continued processing tasks, the kind a person
/// starts and can see. This is the only file that touches that API.
///
/// iOS may decline (the request fails) or end the task early. Declined, the work
/// runs anyway while Ata is open; ended early, `onExpire` puts the meeting back
/// in the queue for the next time Ata is in front.
@MainActor
final class ContinuedWork {
    /// Info.plist permits `ai.interactive.ata.transcribe.*`; each job gets its own suffix,
    /// because a launch handler can be registered only once per identifier.
    static let prefix = "ai.interactive.ata.transcribe"

    private let onExpire: @MainActor () -> Void
    private var task: BGContinuedProcessingTask?
    private var fraction = 0.0
    private var finished = false

    private static let units: Int64 = 1000

    init?(title: String, subtitle: String, onExpire: @escaping @MainActor () -> Void) {
        self.onExpire = onExpire
        guard Self.permitted else { return nil }
        let identifier = "\(Self.prefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let continued = task as? BGContinuedProcessingTask, let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(continued)
            }
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("Ata: transcription will only continue while Ata is open: \(error.localizedDescription)")
            return nil
        }
    }

    /// Registering an identifier Info.plist doesn't permit is a crash, not an error.
    private static var permitted: Bool {
        let ids = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return ids.contains("\(prefix).*")
    }

    func report(_ fraction: Double) {
        self.fraction = min(1, max(0, fraction))
        task?.progress.completedUnitCount = Int64(self.fraction * Double(Self.units))
    }

    func finish(success: Bool) {
        finished = true
        task?.setTaskCompleted(success: success)
        task = nil
    }

    private func attach(_ task: BGContinuedProcessingTask) {
        // Started after the work was already done (the request waited in a queue).
        guard !finished else {
            task.setTaskCompleted(success: true)
            return
        }
        task.progress.totalUnitCount = Self.units
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.expire() }
            }
        }
        self.task = task
        report(fraction)
    }

    private func expire() {
        guard !finished else { return }
        onExpire()
        finish(success: false)
    }
}
