import Foundation

/// Undoes the system-audio files Ata 2.11 wrote at double speed, and says so.
///
/// The writer kept about half of each callback and, once the shortfall passed
/// a tenth of a second, filled the rest with digital silence. On a broken
/// track that silence chops the sound into pieces, and none of those pieces
/// is longer than a second. A healthy track is the opposite: almost all of
/// its sound sits in stretches longer than a second. Under 5% in those long
/// stretches, the meeting is corrupt.
///
/// Repair stretches the short pieces back to the speed they were spoken and
/// copies anything already longer than a second unchanged. The silence stays
/// where it was. The half of each buffer that was never written is still
/// gone. The original file is kept as `system.corrupted.<ext>`, and the
/// meeting is flagged so the window and the transcript say what happened.
enum SystemAudioRepair {
    /// Exact zeros, plus the single code a converter may leave. Room tone is
    /// nowhere near this, which is what keeps an ordinary pause from splitting
    /// a stretch of speech.
    static let silenceCeiling: Int16 = 1
    /// Content in a stretch longer than this is already at the speed it was
    /// spoken. A corrupt track has essentially none of these.
    static let longChunkSeconds = 1.0
    /// Below this share of the content, the track is the 2.11 corruption.
    /// Healthy recordings keep 80–90% of their sound in stretches over a second.
    static let corruptBelowLongShare = 0.05
    /// Shorter than this, a handful of blips proves nothing.
    static let minimumSeconds = 5.0
    /// Silence has to last this long before it splits one stretch from the next.
    /// A single sample at a zero crossing is not a gap.
    static let splitSilenceSeconds = 0.05

    private struct Run {
        var silence: Bool
        var range: Range<Int>
    }

    /// Share of the audible samples that sit in a stretch longer than a second.
    /// 1 when the file holds no sound, so silence alone is not called corrupt.
    static func longContentShare(_ samples: [Int16], sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 1 }
        var content = 0
        var long = 0
        for run in runs(samples, sampleRate: sampleRate) where !run.silence {
            let n = run.range.count
            content += n
            if Double(n) / sampleRate > longChunkSeconds { long += n }
        }
        guard content > 0 else { return 1 }
        return Double(long) / Double(content)
    }

    /// True when under 5% of the sound is in stretches longer than a second.
    static func isCorrupt(_ samples: [Int16], sampleRate: Double) -> Bool {
        guard sampleRate > 0, Double(samples.count) / sampleRate >= minimumSeconds else { return false }
        return longContentShare(samples, sampleRate: sampleRate) < corruptBelowLongShare
    }

    /// The samples with each short stretch slowed to 1× and each long stretch
    /// copied as it was, or nil when the track is not corrupt.
    static func repaired(_ samples: [Int16], sampleRate: Double) -> [Int16]? {
        guard isCorrupt(samples, sampleRate: sampleRate) else { return nil }
        var out: [Int16] = []
        out.reserveCapacity(samples.count * 3 / 2)
        for run in runs(samples, sampleRate: sampleRate) {
            let slice = Array(samples[run.range])
            if run.silence || Double(slice.count) / sampleRate > longChunkSeconds {
                out.append(contentsOf: slice)
            } else {
                out.append(contentsOf: stretchTwice(slice))
            }
        }
        return out
    }

    /// Twice as long, with a sample between each pair so the slowed audio is
    /// not a staircase. Same length change as playing that stretch at half speed.
    static func stretchTwice(_ samples: [Int16]) -> [Int16] {
        guard !samples.isEmpty else { return [] }
        var out = [Int16]()
        out.reserveCapacity(samples.count * 2)
        for i in 0..<samples.count {
            let here = Int(samples[i])
            let next = Int(i + 1 < samples.count ? samples[i + 1] : samples[i])
            out.append(samples[i])
            out.append(Int16(clamping: (here + next) / 2))
        }
        return out
    }

    /// Repairs `system.wav` or `system.m4a` in a meeting folder. The waveform
    /// and the mixed MP3 are removed: both were drawn from the broken track,
    /// and both are rebuilt from the repaired one. False when there is nothing
    /// to do.
    static func repairSystemTrack(in dir: URL) -> Bool {
        let wav = dir.appendingPathComponent("system.wav")
        let m4a = dir.appendingPathComponent("system.m4a")
        let source: URL
        if Paths.fileSize(wav) > 44 {
            source = wav
        } else if Paths.fileSize(m4a) > 0 {
            source = m4a
        } else {
            return false
        }
        let backup = dir.appendingPathComponent("system.corrupted.\(source.pathExtension)")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return false }
        guard let samples = try? readSamples(source),
              let fixed = repaired(samples, sampleRate: WavWriter.sampleRate) else { return false }

        let temporary = dir.appendingPathComponent("system.repairing.wav")
        do {
            try writeWAV(fixed, to: temporary)
            try FileManager.default.moveItem(at: source, to: backup)
            if FileManager.default.fileExists(atPath: wav.path) {
                try FileManager.default.removeItem(at: wav)
            }
            try FileManager.default.moveItem(at: temporary, to: wav)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("waveform.bin"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("meeting.mp3"))
            NSLog("Ata: repaired \(backup.lastPathComponent) — short stretches were at double speed, "
                  + "and the original is kept beside it")
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            NSLog("Ata: could not repair \(source.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    /// Stretches of sound, split only by silence long enough to be a gap.
    /// A zero crossing is one quiet sample, and it stays inside the stretch:
    /// treating it as a gap chopped a tone into a thousand corrupt pieces.
    private static func runs(_ samples: [Int16], sampleRate: Double) -> [Run] {
        let splitAt = Int(splitSilenceSeconds * sampleRate)
        var raw: [(gap: Bool, range: Range<Int>)] = []
        var i = 0
        while i < samples.count {
            // `magnitude`, not `abs`: a clipped sample can be Int16.min, whose
            // absolute value does not exist, and Swift traps on it. That is the
            // 3.0.0/3.0.1 launch crash — one clipped sample in a healthy
            // meeting, reached by this scan on every launch.
            let quiet = samples[i].magnitude <= silenceCeiling.magnitude
            let start = i
            while i < samples.count, (samples[i].magnitude <= silenceCeiling.magnitude) == quiet { i += 1 }
            raw.append((quiet && (i - start) >= splitAt, start..<i))
        }
        var out: [Run] = []
        for piece in raw {
            if piece.gap {
                out.append(Run(silence: true, range: piece.range))
            } else if var last = out.last, !last.silence {
                last.range = last.range.lowerBound..<piece.range.upperBound
                out[out.count - 1] = last
            } else {
                out.append(Run(silence: false, range: piece.range))
            }
        }
        return out
    }

    private static func readSamples(_ url: URL) throws -> [Int16] {
        let reader = try PCM16Reader(url)
        var samples: [Int16] = []
        while let block = try reader.next() { samples.append(contentsOf: block) }
        return samples
    }

    private static func writeWAV(_ samples: [Int16], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: WavWriter.header(dataBytes: UInt32(clamping: samples.count * 2)))
        try samples.withUnsafeBytes { raw in
            try handle.write(contentsOf: Data(raw))
        }
    }
}
