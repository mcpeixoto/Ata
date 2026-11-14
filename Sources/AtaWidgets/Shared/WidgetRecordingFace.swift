import Foundation

/// What the home-screen widget draws while a recording is going: a live timer,
/// or the elapsed audio standing still through a pause. The anchor is
/// `now - recordedSeconds`, so a pause is left out and resume continues
/// from the same length. The same clock as the Live Activity's paused timer.
struct WidgetRecordingFace: Equatable {
    var recordingSince: Date?
    var pausedSeconds: Double?

    var isRecording: Bool { recordingSince != nil || pausedSeconds != nil }

    static func face(isRecording: Bool, isPaused: Bool, recordedSeconds: Double, now: Date) -> WidgetRecordingFace {
        guard isRecording else { return WidgetRecordingFace() }
        if isPaused { return WidgetRecordingFace(pausedSeconds: recordedSeconds) }
        return WidgetRecordingFace(recordingSince: now.addingTimeInterval(-recordedSeconds))
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
