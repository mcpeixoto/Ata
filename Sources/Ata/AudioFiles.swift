import AVFoundation
import Foundation

/// Operations on the recorded WAV tracks: splitting them for upload and
/// compressing them to m4a once a transcript exists.
enum AudioFiles {
    /// One piece of a split recording.
    struct Chunk {
        let url: URL
        /// Where this piece starts inside the original recording, in milliseconds.
        let offsetMs: Int
        /// True when the file is a temporary copy that the caller should delete.
        let temporary: Bool
    }

    /// Splits a 16 kHz mono 16-bit WAV into pieces of at most `maxSeconds`.
    ///
    /// The tracks Ata records are raw PCM with a fixed 44-byte header, so a split
    /// is a byte-range copy plus a fresh header — no decoding, no resampling.
    /// A file that already fits is returned as-is.
    static func split(_ url: URL, maxSeconds: Int, into dir: URL) throws -> [Chunk] {
        let header = 44
        let bytesPerSecond = Int(WavWriter.sampleRate) * 2
        let total = Int(Paths.fileSize(url)) - header
        guard total > 0 else { return [] }
        if total <= maxSeconds * bytesPerSecond {
            return [Chunk(url: url, offsetMs: 0, temporary: false)]
        }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var chunks: [Chunk] = []
        var offset = 0
        var index = 0
        while offset < total {
            // Keep the cut on a whole sample so the piece never starts mid-frame.
            let length = min(maxSeconds * bytesPerSecond, total - offset) / 2 * 2
            guard length > 0 else { break }
            try handle.seek(toOffset: UInt64(header + offset))
            guard let payload = try handle.read(upToCount: length), !payload.isEmpty else { break }

            let piece = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(index).wav")
            var data = WavWriter.header(dataBytes: UInt32(payload.count))
            data.append(payload)
            try data.write(to: piece, options: .atomic)

            chunks.append(Chunk(url: piece,
                                offsetMs: offset / 2 * 1000 / Int(WavWriter.sampleRate),
                                temporary: true))
            offset += payload.count
            index += 1
        }
        return chunks
    }

    /// Copies samples `range` of a 16 kHz mono 16-bit WAV into a WAV of its own.
    static func copySamples(_ url: URL, _ range: Range<Int>, to destination: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(44 + range.lowerBound * 2))
        let payload = try handle.read(upToCount: range.count * 2) ?? Data()
        var data = WavWriter.header(dataBytes: UInt32(payload.count))
        data.append(payload)
        try data.write(to: destination, options: .atomic)
    }

    static func cleanUp(_ chunks: [Chunk]) {
        for c in chunks where c.temporary {
            try? FileManager.default.removeItem(at: c.url)
        }
    }

    /// Re-encodes a WAV to AAC in an m4a container and deletes the WAV on success.
    ///
    /// Speech at 16 kHz mono shrinks roughly tenfold, which is what makes keeping
    /// every recording by default practical.
    @discardableResult
    static func compressToM4A(_ wav: URL) async -> URL? {
        guard Paths.fileSize(wav) > 44 else { return nil }
        let out = wav.deletingPathExtension().appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: out)

        let asset = AVURLAsset(url: wav)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        session.outputURL = out
        session.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed, Paths.fileSize(out) > 0 else {
            if let error = session.error { NSLog("Ata: m4a export failed: \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        try? FileManager.default.removeItem(at: wav)
        return out
    }

    /// Decodes any audio file the system can read back into the 16 kHz mono WAV
    /// shape whisper.cpp expects. Used when re-transcribing a recording whose
    /// WAV has already been replaced by a compressed m4a.
    static func decodeToWAV(_ source: URL, to destination: URL) throws {
        let reader = try PCM16Reader(source)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: WavWriter.header(dataBytes: 0))

        var bytesWritten = 0
        while let block = try reader.next() {
            let data = block.withUnsafeBufferPointer { Data(buffer: $0) }
            try handle.write(contentsOf: data)
            bytesWritten += data.count
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WavWriter.header(dataBytes: UInt32(clamping: bytesWritten)))
    }
}

/// Reads any audio file the system can decode as 16 kHz mono 16-bit samples,
/// one block at a time, so a two-hour meeting never sits in memory.
final class PCM16Reader {
    static let blockFrames: AVAudioFrameCount = 16_384

    private let input: AVAudioFile
    private let converter: AVAudioConverter
    private let inBuffer: AVAudioPCMBuffer
    private let outBuffer: AVAudioPCMBuffer
    private var finished = false

    init(_ url: URL) throws {
        let input = try AVAudioFile(forReading: url)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: WavWriter.sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: target),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: Self.blockFrames),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Self.blockFrames) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.input = input
        self.converter = converter
        self.inBuffer = inBuffer
        self.outBuffer = outBuffer
    }

    /// The next block of samples, or nil once the file is done. A damaged file
    /// throws rather than quietly ending early.
    func next() throws -> [Int16]? {
        while !finished {
            var error: NSError?
            var readError: Error?
            let input = self.input
            let inBuffer = self.inBuffer
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                // AVAudioFile throws when asked to read past the end, so check first:
                // only an error *before* the end means a damaged file.
                if input.framePosition >= input.length {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuffer, frameCount: Self.blockFrames)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let error { throw error }
            // A corrupt file must fail, not quietly become a shorter transcript.
            if let readError { throw readError }
            if status == .endOfStream || status == .error { finished = true }
            if outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData {
                return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
            }
        }
        return nil
    }
}

/// Pieces of a recording cut at pauses, so each stretch of speech can be
/// transcribed in its own language: you may answer in English a moment after
/// speaking Portuguese, and Whisper told to expect one language decodes the
/// other badly or translates it.
enum SpeechChunks {
    /// 30 ms of audio per envelope frame.
    static let frame = Int(WavWriter.sampleRate) * 3 / 100
    /// A pause is at least this many quiet frames (0.6 s).
    static let pauseFrames = 20
    static let minSeconds = 4.0
    static let maxSeconds = 30.0

    /// Sample ranges that cover the whole recording, back to back, cut in the
    /// middle of pauses; a stretch with no pause longer than 30 s is cut at its
    /// quietest moment.
    static func split(_ url: URL) throws -> [Range<Int>] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let count = max(0, (data.count - 44) / 2)
        let frames = count / frame
        var db = [Double](repeating: -100, count: frames)
        data.withUnsafeBytes { raw in
            guard count > 0 else { return }
            let pcm = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for f in 0..<frames {
                var sum = 0.0
                for i in (f * frame)..<((f + 1) * frame) {
                    let v = Double(Int16(littleEndian: pcm[i])) / 32_768
                    sum += v * v
                }
                db[f] = 10 * log10(sum / Double(frame) + 1e-10)
            }
        }
        return pieces(db: db, samples: count)
    }

    /// The cutting rule on an energy envelope in dB, one value per `frame` samples.
    static func pieces(db: [Double], samples: Int) -> [Range<Int>] {
        let rate = WavWriter.sampleRate
        let minFrames = Int(minSeconds * rate) / frame
        let maxFrames = Int(maxSeconds * rate) / frame
        guard samples > 0 else { return [] }
        guard db.count > minFrames else { return [0..<samples] }

        // Quiet: 20 dB under the speech. Measured from the speech rather than the noise
        // floor, so a track that is talk from start to end still finds its pauses; in a
        // noisy room that hides them, long stretches are cut at their quietest moment.
        let threshold = db.sorted()[db.count * 9 / 10] - 20
        var pauses: [Int] = []  // frame in the middle of each pause
        var run = 0
        for (f, v) in db.enumerated() {
            if v < threshold { run += 1 } else {
                if run >= pauseFrames { pauses.append(f - run / 2) }
                run = 0
            }
        }

        var cuts: [Int] = []
        var start = 0
        func quietest(in r: Range<Int>) -> Int {
            r.min { db[$0] < db[$1] } ?? r.upperBound
        }
        for p in pauses + [db.count] {
            while p - start > maxFrames {
                // No pause in time: cut at the quietest moment of the last third.
                let c = quietest(in: (start + maxFrames * 2 / 3)..<(start + maxFrames))
                cuts.append(c)
                start = c
            }
            if p < db.count, p - start >= minFrames {
                cuts.append(p)
                start = p
            }
        }
        // The tail joins the last piece when it is too short to judge on its own.
        if let last = cuts.last, db.count - last < minFrames { cuts.removeLast() }

        var out: [Range<Int>] = []
        var from = 0
        for c in cuts {
            out.append(from..<(c * frame))
            from = c * frame
        }
        out.append(from..<samples)
        return out
    }
}
