#if os(macOS)
import Foundation

/// Which step of the welcome window to show, decided from what is true now, so
/// the restart that system audio needs lands on the right one by itself.
enum SetupStep: Int {
    case recording = 1, summaries, done

    static func current(mic: Bool, systemAudioMissing: Bool, apple: AppleIntelligenceState,
                        summariesPassed: Bool) -> SetupStep {
        if !mic || systemAudioMissing { return .recording }
        // Nothing to ask of a Mac that can't run it, or that already does.
        let asks = apple == .off || apple == .preparing
        return asks && !summariesPassed ? .summaries : .done
    }
}

/// Room for the model, with a margin so the download can't fill the disk.
enum DiskCheck {
    static let margin: Int64 = 500_000_000

    static func hasRoom(available: Int64?, needed: Int64) -> Bool {
        // Not knowing is no reason to refuse.
        guard let available else { return true }
        return available >= needed + margin
    }

    static func available(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// A recording of about an hour at the raw rate of both tracks.
    static let lowForRecording: Int64 = 250_000_000
}

/// Login items and the updater need the app to stay where it is, which a copy
/// running from a disk image or from Downloads won't.
enum InstallLocation {
    static func isSettled(_ bundlePath: String, home: String) -> Bool {
        bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/Applications/")
    }
}

/// Why a queued meeting is not being transcribed, in words a person can act on.
enum QueueReason {
    static func text(whisper: Bool, model: Bool, progress: Double?, error: String?) -> String? {
        if !whisper { return L("Ata's transcription program is missing. Install Ata again to fix it.") }
        if model { return nil }
        if let progress { return L("Waiting for Whisper Large to download (%d%%).", Int(progress * 100)) }
        if let error { return L("Whisper Large did not download: %@", error) }
        return L("Waiting for Whisper Large to download.")
    }
}

/// Meetings transcribed while Apple Intelligence was off get their summary once it is on.
enum SummaryBackfill {
    static func shouldMark(summarize: Bool, appleAvailable: Bool, words: Int) -> Bool {
        summarize && !appleAvailable && words > 0
    }
}
#endif
