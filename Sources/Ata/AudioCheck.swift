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

    /// What to write when the frames in ordinary callbacks didn't fill the time
    /// those callbacks covered. `ratio` is audio-seconds per host-second, measured
    /// before any silence was inserted to hide the gap. `corrected` means the
    /// samples were rewritten at the rate they actually arrived, so the file
    /// itself should play at the right speed.
    static func deliveryReport(track: String, ratio: Double, corrected: Bool, formats: [String]) -> String {
        let speed = ratio < 1
            ? String(format: "about %.1f× too fast", 1 / max(ratio, 0.001))
            : String(format: "about %.1f× too slow", max(ratio, 0.001))
        let seen = formats.isEmpty ? "unknown" : formats.joined(separator: ", ")
        let outcome = corrected
            ? "It was written at the rate the samples actually came in, so this recording should play at the right speed."
            : "It was not a rate Ata knows how to repair, so this recording may play at the wrong speed."
        return String(format: "Ata: %@ delivered audio at %.2f× the rate its format claimed — %@. %@ Format(s) seen: %@.",
                      track, ratio, speed, outcome, seen)
    }
}

/// One track's pace, snapshotted at the end of a recording — after that the
/// writer is closed and the counts are gone.
struct CapturePace: Equatable {
    var track: String
    /// Audio-seconds per host-second over ordinary callbacks. Nil until there
    /// is a second of them.
    var deliveryRatio: Double?
    var corrected: Bool
    var formats: [String]
    var fileSeconds: Double
    var hostSeconds: Double?
}

/// Whether each side of a recording actually held any sound.
///
/// A process tap that is pointed at nothing — the call went to headphones Ata
/// could not follow, the permission lapsed, the output device changed under
/// it — delivers perfect digital silence, forever. Every check Ata had was
/// satisfied by it: buffers arrive, the file is the right length, the WAV is
/// valid. The meeting "succeeds" and only later does anyone notice the other
/// side of the call is simply not in the transcript.
///
/// This is the check that notices. It reads the waveform lanes Ata already
/// computes (50 ms levels per track), so it costs nothing, and its verdict is
/// written into the transcript rather than a log nobody reads.
enum TrackHealth: String, Equatable {
    /// Both sides held sound.
    case fine
    /// The system track is digital silence while you were talking: the other
    /// side of the call was never captured.
    case othersNotCaptured
    /// Your microphone track is digital silence while the others were talking.
    case youNotCaptured
    /// The system track was the 2.11 double-speed corruption. Ata has slowed
    /// the short stretches back down. Shown so the person reading knows the
    /// other side was repaired, and that part of it was never captured.
    case systemAudioCorrupt

    /// Less sound than this on a track is no sound. A tap is digital silence
    /// while nothing plays; a real side of a call crosses this in seconds.
    static let silentBelowSeconds = 1.0
    /// Shorter than this, an empty side proves nothing: people join late,
    /// and a false alarm here teaches people to ignore the real one.
    static let minimumMeetingSeconds = 60.0
    /// You have to have been heard for this long before your side counts as
    /// "your side was captured" — otherwise a silent room would warn too.
    static let minimumSpeechSeconds = 5.0

    /// `micAudible`/`systemAudible`: seconds above the waveform's own
    /// audibility floor, per track (see `SpeakerRoute.audibleSeconds`).
    /// `systemPresent` is false for a meeting in the room, where there is no
    /// other side to lose and a silent system track is expected.
    static func judge(duration: Double, micAudible: Double, systemAudible: Double,
                      systemPresent: Bool) -> TrackHealth {
        guard duration >= minimumMeetingSeconds else { return .fine }
        if systemPresent, systemAudible < silentBelowSeconds, micAudible >= minimumSpeechSeconds {
            return .othersNotCaptured
        }
        if micAudible < silentBelowSeconds, systemAudible >= minimumSpeechSeconds {
            return .youNotCaptured
        }
        return .fine
    }

    /// The line written at the top of the transcript and shown in the meeting
    /// window, or nil when there is nothing to say.
    var warning: String? {
        switch self {
        case .fine: return nil
        case .othersNotCaptured:
            return L("Ata could not hear the other side of this call: the system audio track is silent, so only your side could be transcribed. Check that the call plays through the Mac's chosen output device, and that Ata still has System Audio permission in System Settings → Privacy & Security.")
        case .youNotCaptured:
            return L("Ata could not hear you in this recording: the microphone track is silent, so only the other side could be transcribed. Check the microphone in System Settings → Privacy & Security → Microphone.")
        case .systemAudioCorrupt:
            return L("The other side of this recording was corrupted: it arrived in pieces shorter than a second, playing too fast. Ata slowed those pieces back down. Longer stretches were left as recorded, and anything that was never captured is still missing.")
        }
    }
}
