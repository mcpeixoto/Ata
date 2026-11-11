import Foundation

/// How long the transcription running now has left: this Mac's own pace on
/// earlier meetings to begin with, the bar's pace once it has moved.
enum TranscribeETA {
    /// Seconds of work per second of audio, the median of the last ten
    /// transcripts made with this model. Nil until there is one.
    static func rate(_ records: [TranscriptionRecord], model: String) -> Double? {
        let ratios = records
            .filter { $0.model == model && $0.audioSeconds >= 60 && $0.processingSeconds > 0 }
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(10)
            .map { $0.processingSeconds / $0.audioSeconds }
            .sorted()
        guard !ratios.isEmpty else { return nil }
        return ratios[ratios.count / 2]
    }

    /// Seconds left, or nil when there is nothing to go on yet.
    ///
    /// The bar's own pace (time so far over the share done) says little in the
    /// first minute, when the model is still loading, so it only counts from
    /// a tenth of the way, and weighs more the further the bar has gone.
    static func remaining(progress p: Double, elapsed: TimeInterval, expected: TimeInterval?) -> TimeInterval? {
        let fromHistory = expected.map { max(0, $0 - elapsed) }
        guard p >= 0.1, p < 1, elapsed >= 30 else { return fromHistory }
        let fromBar = elapsed * (1 - p) / p
        guard let fromHistory else { return fromBar }
        return p * fromBar + (1 - p) * fromHistory
    }

    static func text(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return L("Less than a minute left") }
        if minutes < 60 { return L("About %d min left", minutes) }
        return L("About %d h %d min left", minutes / 60, minutes % 60)
    }
}
