import EventKit
import Foundation

/// Permission to read the user's calendar.
///
/// Shaped like `SetupModel`'s microphone handling rather than its system-audio
/// handling: EventKit is a public API with no private entry points to load, and
/// a grant applies to the process that is already running, so there is nothing
/// to restart. Ask when it has not been asked; otherwise open the settings pane,
/// because macOS will not ask twice.
///
/// EventKit has no read-only tier. Reading events requires *full* access, which
/// also permits writing — Apple's shape, not a choice. Ata asks for it only when
/// the user turns the feature on, says so in the usage string and in Settings,
/// and `CalendarStore` never imports a write API, so writing to a calendar would
/// have to be a deliberate edit rather than a slip.
enum CalendarAccess {
    enum Status: Equatable {
        case authorized, denied, notDetermined
        /// Allowed to add events but not to read them — no use here, and the
        /// user has to widen it in the settings pane.
        case writeOnly
    }

    static var status: Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .authorized
        case .notDetermined: return .notDetermined
        case .writeOnly: return .writeOnly
        // `.authorized` is the pre-macOS 14 spelling and still appears for an
        // app granted access before the full/write-only split.
        case .authorized: return .authorized
        default: return .denied
        }
    }

    static var isAuthorized: Bool { status == .authorized }

    /// What to do after asking — because asking does not always ask.
    ///
    /// A hardened-runtime app needs the
    /// `com.apple.security.personal-information.calendars` entitlement for
    /// macOS to show the dialog at all, and even with it, `tccd` stays silent
    /// when the process responsible for Ata's launch has no such right — Ata
    /// started from a terminal, or by another app. The request then returns
    /// false with the status unchanged and nothing appears on screen. A button
    /// that does nothing is the worst possible answer, so that case opens the
    /// settings pane instead.
    enum NextStep: Equatable {
        /// Granted, or just refused by the user — who does not need to be sent
        /// to System Settings a second after saying no.
        case nothing
        /// macOS never asked, or had already been answered: the pane is the
        /// only route left.
        case openSettings
    }

    static func nextStep(before: Status, after: Status) -> NextStep {
        if after == .authorized { return .nothing }
        if before == .notDetermined, after != .notDetermined { return .nothing }
        return .openSettings
    }

    /// Whether a request went by without macOS asking anything.
    static func wasSilent(before: Status, after: Status) -> Bool {
        before == .notDetermined && after == .notDetermined
    }

    /// Shows the system prompt. Returns whether Ata may now read the calendar.
    static func request() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            NSLog("Ata: calendar access was refused: \(error.localizedDescription)")
            return false
        }
    }
}
