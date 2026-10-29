import Foundation

/// Undoes the system-audio files Ata 2.11 wrote at double speed.
///
/// Each callback kept about half its frames, and once the shortfall passed a
/// tenth of a second the writer filled it with digital silence so the file
/// still matched the clock. The speech that remains is intelligible at half
/// speed; the silence is padding, not a pause anyone took. Stripping those
/// pads and stretching what is left by two puts that speech back at the speed
/// it was spoken. The half of each buffer that was never written is gone, and
/// this does not invent it.
///
/// The original file is kept beside the meeting as `system.corrupted.<ext>`.
/// A second launch finds that name and does nothing.
enum SystemAudioRepair {
    /// Exact zeros, plus the single code a converter may leave. Room tone is
    /// nowhere near this, which is what keeps an ordinary pause from matching.
    static let silenceCeiling: Int16 = 1
    static let minGapSeconds = 0.06
    static let maxGapSeconds = 0.25
    /// The pads land about five times a second. One a second is already more
    /// digital silence than speech ever contains.
    static let minGapsPerSecond = 1.0
    static let minGapShare = 0.2
    static let maxGapShare = 0.7

    /// The samples with the padding removed and the rest slowed to 1×, or nil
    /// when this is not that corruption.
    static func samples(removingPads samples: [Int16], sampleRate: Double) -> [Int16]? {
        guard sampleRate > 0, samples.count > Int(sampleRate) else { return nil }
        let minRun = Int(minGapSeconds * sampleRate)
        let maxRun = Int(maxGapSeconds * sampleRate)
        var gaps: [Range<Int>] = []
        var i = 0
        while i < samples.count {
            if abs(samples[i]) <= silenceCeiling {
                let start = i
                while i < samples.count, abs(samples[i]) <= silenceCeiling { i += 1 }
                let length = i - start
                if length >= minRun, length <= maxRun { gaps.append(start..<i) }
            } else {
                i += 1
            }
        }
        let seconds = Double(samples.count) / sampleRate
        guard seconds >= 5, Double(gaps.count) / seconds >= minGapsPerSecond else { return nil }
        let gapSamples = gaps.reduce(0) { $0 + $1.count }
        let share = Double(gapSamples) / Double(samples.count)
        guard share >= minGapShare, share <= maxGapShare else { return nil }

        var kept: [Int16] = []
        kept.reserveCapacity(samples.count - gapSamples)
        var cursor = 0
        for gap in gaps {
            if cursor < gap.lowerBound { kept.append(contentsOf: samples[cursor..<gap.lowerBound]) }
            cursor = gap.upperBound
        }
        if cursor < samples.count { kept.append(contentsOf: samples[cursor..<samples.count]) }
        guard kept.count > Int(sampleRate) else { return nil }
        return stretchTwice(kept)
    }

    /// Twice as long, with a sample between each pair so the slowed audio is
    /// not a staircase. Same length change as playing the file at half speed.
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
              let repaired = Self.samples(removingPads: samples, sampleRate: WavWriter.sampleRate) else { return false }

        let temporary = dir.appendingPathComponent("system.repairing.wav")
        do {
            try writeWAV(repaired, to: temporary)
            try FileManager.default.moveItem(at: source, to: backup)
            if FileManager.default.fileExists(atPath: wav.path) {
                try FileManager.default.removeItem(at: wav)
            }
            try FileManager.default.moveItem(at: temporary, to: wav)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("waveform.bin"))
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("meeting.mp3"))
            NSLog("Ata: repaired \(backup.lastPathComponent) — the other side was at double speed, "
                  + "and the original is kept beside it")
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            NSLog("Ata: could not repair \(source.lastPathComponent): \(error.localizedDescription)")
            return false
        }
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
