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
/// gone. The original file is kept as `system.corrupted.<ext>`. A later
/// launch rebuilds from that original — never from the wav the repair just
/// wrote, which is how a track got slowed a second time — and leaves
/// `system.repair` so the folder is not decoded on every launch.
enum SystemAudioRepair {
    /// A sample this small is silence on its own. A 20 ms window whose RMS is
    /// under −90 dBFS counts as silence too: a decoder can leave a few spikes
    /// of a couple of codes in a digital gap, and those spikes used to glue
    /// the short pieces into one long stretch so the corruption was missed.
    /// Room tone and quiet speech are far louder than either test, which is
    /// what keeps an ordinary pause from splitting a stretch of speech.
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
    /// How wide a window is when a spike, rather than the sample itself, is
    /// what might be hiding a gap.
    static let silenceWindowSeconds = 0.020
    /// Written into `system.repair` once this repair has judged the folder.
    /// An older repair, or none, is redone from the kept original: that
    /// repair looked for a backup named with the file's *current* extension,
    /// so an m4a kept as `system.corrupted.m4a` was invisible once the
    /// repaired file was a wav, and the wav was slowed again.
    static let repairMarker = "2"

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
    /// and the mixed MP3 are removed when the audio changes: both were drawn
    /// from the broken track, and both are rebuilt from the repaired one.
    /// False when there is nothing to do, including when this repair already
    /// judged the folder.
    static func repairSystemTrack(in dir: URL) -> Bool {
        let marker = dir.appendingPathComponent("system.repair")
        if let stamp = try? String(contentsOf: marker, encoding: .utf8),
           stamp.trimmingCharacters(in: .whitespacesAndNewlines) == repairMarker {
            return false
        }

        let wav = dir.appendingPathComponent("system.wav")
        let m4a = dir.appendingPathComponent("system.m4a")
        let backupM4A = dir.appendingPathComponent("system.corrupted.m4a")
        let backupWAV = dir.appendingPathComponent("system.corrupted.wav")

        let source: URL
        let output: [Int16]
        let fromBackup: Bool
        if Paths.fileSize(backupM4A) > 0 {
            // The m4a is the true original when both backups exist. The first
            // repair of an m4a moved it there; a later pass can only have
            // written `system.corrupted.wav` by backing up a wav it had
            // already slowed. If this original is not the corruption, stop:
            // repairing that later wav would slow the track again.
            guard let samples = try? readSamples(backupM4A) else { return false }
            guard let fixed = repaired(samples, sampleRate: WavWriter.sampleRate) else {
                remember(marker)
                return false
            }
            source = backupM4A
            output = fixed
            fromBackup = true
        } else if Paths.fileSize(backupWAV) > 44 {
            guard let samples = try? readSamples(backupWAV) else { return false }
            guard let fixed = repaired(samples, sampleRate: WavWriter.sampleRate) else {
                remember(marker)
                return false
            }
            source = backupWAV
            output = fixed
            fromBackup = true
        } else if Paths.fileSize(wav) > 44 || Paths.fileSize(m4a) > 0 {
            source = Paths.fileSize(wav) > 44 ? wav : m4a
            // Healthy: remember that and leave the file untouched, so the
            // next launch does not decode it again.
            guard let samples = try? readSamples(source) else { return false }
            guard let fixed = repaired(samples, sampleRate: WavWriter.sampleRate) else {
                remember(marker)
                return false
            }
            output = fixed
            fromBackup = false
        } else {
            return false
        }

        let temporary = dir.appendingPathComponent("system.repairing.wav")
        do {
            try writeWAV(output, to: temporary)
            // Already the audio this repair would write. Flagging it again would
            // transcribe a meeting that is already right.
            if fromBackup, sameBytes(temporary, wav) {
                try? FileManager.default.removeItem(at: temporary)
                remember(marker)
                return false
            }
            if !fromBackup {
                let backup = dir.appendingPathComponent("system.corrupted.\(source.pathExtension)")
                // The source is the original. An empty placeholder is not one,
                // but a real backup must not be overwritten, and the file the
                // meeting plays must not be deleted until the original is safe.
                if FileManager.default.fileExists(atPath: backup.path), Paths.fileSize(backup) == 0 {
                    try FileManager.default.removeItem(at: backup)
                }
                guard !FileManager.default.fileExists(atPath: backup.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.moveItem(at: source, to: backup)
            }
            if FileManager.default.fileExists(atPath: wav.path) {
                try FileManager.default.removeItem(at: wav)
            }
            try FileManager.default.moveItem(at: temporary, to: wav)
            // A compressed copy beside the new wav was made from the broken
            // track. The backup, under its own name, stays.
            if FileManager.default.fileExists(atPath: m4a.path) {
                try? FileManager.default.removeItem(at: m4a)
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("waveform.bin"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("meeting.mp3"))
            remember(marker)
            NSLog("Ata: repaired the system track from \(source.lastPathComponent) — "
                  + "short stretches were at double speed, and the original is kept beside it")
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
        let window = max(1, Int((silenceWindowSeconds * sampleRate).rounded()))
        // −90 dBFS against the full Int16 range. Compared as a sum of squares
        // so a two-hour file never builds a table of energies.
        let rmsCeiling = 32768.0 * pow(10.0, -90.0 / 20.0)
        let rmsCeilingSq = rmsCeiling * rmsCeiling
        var sumSq: Int64 = 0
        var raw: [(gap: Bool, range: Range<Int>)] = []
        var runStart = 0
        var runQuiet = false
        var haveRun = false
        for i in samples.indices {
            // Widen before squaring: Int16.min has no square that fits in 16 bits,
            // and `abs` of it traps. That trap was the 3.0.0/3.0.1 launch crash.
            let value = Int64(samples[i])
            sumSq += value * value
            if i >= window {
                let old = Int64(samples[i - window])
                sumSq -= old * old
            }
            let count = i < window ? i + 1 : window
            let quiet = samples[i].magnitude <= silenceCeiling.magnitude
                || Double(sumSq) <= rmsCeilingSq * Double(count)
            if !haveRun {
                runQuiet = quiet
                haveRun = true
            } else if quiet != runQuiet {
                raw.append((runQuiet && (i - runStart) >= splitAt, runStart..<i))
                runStart = i
                runQuiet = quiet
            }
        }
        if haveRun {
            raw.append((runQuiet && (samples.count - runStart) >= splitAt, runStart..<samples.count))
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

    private static func remember(_ marker: URL) {
        try? Data(repairMarker.utf8).write(to: marker, options: .atomic)
    }

    private static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        guard Paths.fileSize(a) > 0, Paths.fileSize(a) == Paths.fileSize(b),
              let left = try? Data(contentsOf: a),
              let right = try? Data(contentsOf: b) else { return false }
        return left == right
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
