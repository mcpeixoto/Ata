import AppKit
import EventKit
import Foundation
import UserNotifications

/// Keeps a prompt scheduled for each meeting on the calendar worth recording,
/// and starts the recording itself when the user asked for that instead.
///
/// Nothing here runs at the moment a meeting starts. The wall-clock wait belongs
/// to the system: a `Timer` does not fire while the Mac sleeps, and Ata runs for
/// weeks as a login item — the prompt it most needs to deliver is the one for
/// the ten o'clock, on a Mac that was asleep at 09:59.
/// `UNCalendarNotificationTrigger` is the system's job and survives that; a
/// `Timer` would simply have missed it.
///
/// So this only ever *reconciles*: it reads the calendar and makes the set of
/// pending notification requests match what the calendar now says. That happens
/// at launch, whenever the store changes, whenever the Mac wakes, whenever the
/// time zone changes, whenever the settings change, and every fifteen minutes as
/// a safety net.
@MainActor
final class CalendarWatcher {
    static let shared = CalendarWatcher()

    private var observers: [NSObjectProtocol] = []
    private var safetyNet: Timer?
    private var autoStart: Timer?

    /// Occurrences this process has already started a recording for. In memory
    /// on purpose: after a relaunch mid-meeting, starting again is the right
    /// answer, and `startRecording` refuses anyway unless the phase is idle.
    private var ledger = AutoStartLedger()

    private var isOn: Bool {
        Pref.d.bool(forKey: Pref.calendarPrompt) && CalendarAccess.isAuthorized
    }

    private var lead: TimeInterval {
        TimeInterval(max(0, Pref.d.integer(forKey: Pref.calendarLeadMinutes))) * 60
    }

    func start() {
        stop()
        guard isOn else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarWatcher.shared.reconcile() }
            },
            // A prompt scheduled before a flight and fired after it would be an
            // hour out: a trigger is date components in the current zone.
            center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CalendarWatcher.shared.reconcile() }
            },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { CalendarWatcher.shared.reconcile() }
                },
        ]
        safetyNet = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarWatcher.shared.reconcile() }
        }
        // The one clock in here, and only for "start recording on its own":
        // that needs Ata awake, which a sleeping Mac is not — and a sleeping Mac
        // is not in a meeting either.
        autoStart = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarWatcher.shared.startAnythingDue() }
        }
        reconcile()
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        observers = []
        safetyNet?.invalidate(); safetyNet = nil
        autoStart?.invalidate(); autoStart = nil
        Notifier.shared.clearScheduledMeetings()
    }

    /// Read the calendar and make the scheduled prompts match it. Cheap and
    /// idempotent, which is why every signal above can just call it.
    func reconcile() {
        guard isOn else { Notifier.shared.clearScheduledMeetings(); return }
        // With "Start recording" chosen there is nothing to ask, so nothing is
        // scheduled; `startAnythingDue` does the work instead.
        guard !Pref.d.bool(forKey: Pref.autoStart) else {
            Notifier.shared.clearScheduledMeetings()
            return
        }
        let now = Date()
        let due = CalendarSchedule.occurrences(in: CalendarStore.shared.upcoming(now: now), now: now,
                                               lead: lead,
                                               peopleOnly: Pref.d.bool(forKey: Pref.calendarPeopleOnly))
        var wanted: [String: (event: MeetingEvent, fire: Date)] = [:]
        for candidacy in due {
            guard let fire = CalendarSchedule.fireDate(for: candidacy.event, lead: lead, now: now) else { continue }
            wanted[CalendarSchedule.key(for: candidacy.event)] = (event: candidacy.event, fire: fire)
        }
        Notifier.shared.scheduleMeetings(wanted, leadMinutes: Int(lead / 60))
    }

    /// The "Start recording" branch: anything whose moment has come.
    private func startAnythingDue() {
        guard isOn, Pref.d.bool(forKey: Pref.autoStart), AppStore.shared.phase == .idle else { return }
        let now = Date()
        let due = CalendarSchedule.occurrences(in: CalendarStore.shared.upcoming(now: now), now: now,
                                               lead: lead,
                                               peopleOnly: Pref.d.bool(forKey: Pref.calendarPeopleOnly))
        for candidacy in due {
            let key = CalendarSchedule.key(for: candidacy.event)
            guard ledger.mayStart(key),
                  candidacy.event.startsAt.timeIntervalSince(now) <= lead else { continue }
            ledger.attempt(key)
            AppStore.shared.startRecording(app: AppStore.shared.detectedApp, event: candidacy.event) { ok in
                CalendarWatcher.shared.ledger.finished(key, started: ok)
            }
            return
        }
    }
}

/// Which calendar occurrences "Start recording" has dealt with. An occurrence
/// counts as started only once the recording really is running: it used to be
/// marked before the attempt, so a start that failed (a device that vanished, a
/// tap Core Audio refused) was never tried again for that meeting. A failure
/// is retried on the next tick, a few times, and then left alone — a missing
/// permission would otherwise reopen the welcome window every twenty seconds.
struct AutoStartLedger {
    static let maxAttempts = 3

    private(set) var started: Set<String> = []
    private var attempts: [String: Int] = [:]
    private var inFlight: Set<String> = []

    func mayStart(_ key: String) -> Bool {
        !started.contains(key) && !inFlight.contains(key) && attempts[key, default: 0] < Self.maxAttempts
    }

    mutating func attempt(_ key: String) {
        attempts[key, default: 0] += 1
        inFlight.insert(key)
    }

    mutating func finished(_ key: String, started ok: Bool) {
        inFlight.remove(key)
        if ok { started.insert(key) }
    }
}
