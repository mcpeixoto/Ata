import Foundation

/// Does a recording's audio last as long as the recording ran?
///
/// It always should. The two numbers come from completely different places —
/// one from counting samples written, the other from the clock — so when they
/// disagree, something between the microphone and the file converted the audio
/// by the wrong ratio. The usual cause is an input whose real format was not
/// the one the audio engine reported.
///
/// Nothing else in Ata would notice. The WAV is a valid WAV whatever ratio was
/// used; it simply plays back too fast or too slow, and the transcript comes
/// out as nonsense because no speech model can read speech at the wrong speed.
/// This is the one check that can tell, and it costs two divisions.
enum AudioCheck {
    /// Out by more than this and something is wrong. Generous: a recording can
    /// legitimately lose a moment at either end, and a false alarm about a good
    /// recording is worse than none, because it would teach people to ignore it.
    static let tolerance = 0.1

    /// How far the audio is from the time that passed, as a share of that time.
    /// Positive means the file holds more than it should, negative less. Nil
    /// when there is nothing to compare — too short to judge, or no clock.
    static func drift(audioSeconds: Double, elapsed: Double) -> Double? {
        guard elapsed >= 5, audioSeconds > 0 else { return nil }
        return (audioSeconds - elapsed) / elapsed
    }

    /// Whether that drift is worth telling someone about.
    static func isSuspect(audioSeconds: Double, elapsed: Double) -> Bool {
        guard let drift = drift(audioSeconds: audioSeconds, elapsed: elapsed) else { return false }
        return abs(drift) > tolerance
    }

    /// What to write in the log when it is. Says the ratio in the form a person
    /// would recognise it — "plays back about 3.0× too fast" — and names the
    /// formats, because that is the evidence needed to fix it.
    static func report(audioSeconds: Double, elapsed: Double, formats: [String]) -> String {
        let ratio = elapsed / max(audioSeconds, 0.001)
        let speed = ratio > 1
            ? String(format: "about %.1f× too fast", ratio)
            : String(format: "about %.1f× too slow", 1 / max(ratio, 0.001))
        let seen = formats.isEmpty ? "unknown" : formats.joined(separator: ", ")
        return String(format: "Ata: this recording's audio is %.1fs but it ran for %.1fs — it will play back %@. "
                      + "Microphone format(s) seen: %@", audioSeconds, elapsed, speed, seen)
    }
}
