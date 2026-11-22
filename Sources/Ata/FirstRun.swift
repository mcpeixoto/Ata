import Foundation

/// Whether a ten-second trial heard each side, from the loudest sample.
/// The iPhone has no system-audio track, so it passes `peakMac` as 0.
struct TrialResult: Equatable {
    var heardMic: Bool
    var heardMac: Bool

    init(heardMic: Bool, heardMac: Bool) {
        self.heardMic = heardMic
        self.heardMac = heardMac
    }

    /// The microphone counts from 0.05: below that is room tone. System audio
    /// is quieter, so a call in the speakers still counts from 0.01. Same
    /// lines the Mac trial used before this was shared.
    init(peakMic: Float, peakMac: Float) {
        self.init(heardMic: peakMic >= 0.05, heardMac: peakMac >= 0.01)
    }
}

#if os(macOS)

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

/// The steps of the welcome window, in order. The raw value is what
/// `Pref.onboardingStep` stores and what `Funnel` counts, so never renumber.
enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome = 0, permissions, summaries, you, test, done

    static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.rawValue < b.rawValue }

    /// Summaries only for a Mac where Apple Intelligence can still be turned on.
    static func sequence(apple: AppleIntelligenceState) -> [OnboardingStep] {
        let asks = apple == .off || apple == .preparing
        return allCases.filter { $0 != .summaries || asks }
    }

    /// The first step that is still owed: the welcome until it has been passed,
    /// then permissions while the microphone or Mac audio is missing.
    static func firstUnmet(persisted: Int?, mic: Bool, systemAudioMissing: Bool) -> OnboardingStep? {
        if (persisted ?? -1) < OnboardingStep.permissions.rawValue { return .welcome }
        return !mic || systemAudioMissing ? .permissions : nil
    }

    /// Where the window opens. A first run resumes at the furthest step reached,
    /// so the restart after the Mac audio grant comes back to `permissions`
    /// with its ticks. Reopened after setup was closed ("Finish setting up"), it
    /// goes to what is missing, or straight to the end.
    static func shown(persisted: Int?, onboarded: Bool, mic: Bool, systemAudioMissing: Bool,
                      apple: AppleIntelligenceState) -> OnboardingStep {
        // Someone who finished setup has seen the welcome, whatever was stored.
        if onboarded { return !mic || systemAudioMissing ? .permissions : .done }
        let unmet = firstUnmet(persisted: persisted, mic: mic, systemAudioMissing: systemAudioMissing)
        let saved = resolve(persisted ?? 0, apple: apple)
        return max(saved, unmet ?? saved)
    }

    /// A stored step that this Mac does not show (summaries, once Apple
    /// Intelligence is on) becomes the next one it does.
    static func resolve(_ raw: Int, apple: AppleIntelligenceState) -> OnboardingStep {
        let steps = sequence(apple: apple)
        return steps.first { $0.rawValue >= raw } ?? .done
    }

    func next(apple: AppleIntelligenceState) -> OnboardingStep {
        let steps = Self.sequence(apple: apple)
        return steps.first { $0 > self } ?? .done
    }

    func previous(apple: AppleIntelligenceState) -> OnboardingStep? {
        Self.sequence(apple: apple).last { $0 < self }
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

    /// On the Mac every summary is written after its transcript, outside the
    /// queue, so any transcript with words owes one when summaries are on.
    static func owed(summarize: Bool, words: Int) -> Bool {
        summarize && words > 0
    }
}
#endif
