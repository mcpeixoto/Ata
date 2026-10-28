import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// Compiled into both the iPhone app and the widget extension: the app starts and
// updates the Live Activity, the extension draws it.

/// How the iPhone records.
enum RecordingMode: String, Codable, CaseIterable, Hashable, Sendable {
    /// A conversation in the room.
    case inPerson
    /// A call on another device's loudspeaker, with the iPhone listening in the room.
    case callOnSpeaker

    var title: String {
        switch self {
        case .inPerson: return L("In person")
        case .callOnSpeaker: return L("Call on speaker")
        }
    }

    var symbol: String {
        switch self {
        case .inPerson: return "person.2.fill"
        case .callOnSpeaker: return "speaker.wave.2.fill"
        }
    }

    /// The meeting's app label, which is also its title and part of its folder name.
    var meetingApp: String? {
        switch self {
        case .inPerson: return nil
        case .callOnSpeaker: return L("Call")
        }
    }

    /// Apple's voice processing (echo cancellation, noise suppression, gain) is
    /// tuned for a person talking into the phone. A call coming out of another
    /// device's speaker is exactly what it is built to suppress, so that mode
    /// records the microphone as it is. Whether in person is better with or
    /// without it is measured before the first TestFlight build.
    var usesVoiceProcessing: Bool { self == .inPerson }
}

#if canImport(ActivityKit) && os(iOS)
/// The recording, as the lock screen and the Dynamic Island show it.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When a recording as long as this one would have started, so the
        /// timer shows the audio recorded, without the time spent interrupted.
        var timerStart: Date
        /// A call or another app has the microphone; the timer stands still.
        var isPaused: Bool
        /// The recorded length when it paused, for the stopped timer.
        var pausedSeconds: Double
        var bookmarks: Int
    }

    var mode: RecordingMode
}
#endif

/// What the widgets show, written by the app into the app group they share.
struct WidgetSnapshot: Codable, Equatable {
    var lastTitle: String?
    var lastStartedAt: Date?
    /// Set while recording.
    var recordingSince: Date?

    static let appGroup = "group.ai.interactive.ata"
    private static let key = "widgetSnapshot"

    /// Without the app group entitlement (an unsigned build) this is the app's
    /// own defaults: nothing breaks, the widget just shows nothing.
    private static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }

    static func load() -> WidgetSnapshot {
        guard let data = defaults.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return WidgetSnapshot() }
        return snapshot
    }

    /// True when it changed, so the caller only reloads widgets when it has to.
    @discardableResult
    func save() -> Bool {
        guard self != Self.load(), let data = try? JSONEncoder().encode(self) else { return false }
        Self.defaults.set(data, forKey: Self.key)
        return true
    }
}
