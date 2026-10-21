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
        let input = try AVAudioFile(forReading: source)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: WavWriter.sampleRate,
                                         channels: 1,
                                         interleaved: true),
              let converter = AVAudioConverter(from: input.processingFormat, to: target) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: WavWriter.header(dataBytes: 0))

        let readSize: AVAudioFrameCount = 16_384
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: readSize),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: readSize) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var bytesWritten = 0
        var finished = false
        var readError: Error?
        while !finished {
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                do {
                    try input.read(into: inBuffer, frameCount: readSize)
                } catch {
                    // A corrupt file must fail, not quietly become a shorter transcript.
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
            if outBuffer.frameLength > 0, let channel = outBuffer.int16ChannelData {
                let count = Int(outBuffer.frameLength) * 2
                try handle.write(contentsOf: Data(bytes: channel[0], count: count))
                bytesWritten += count
            }
            if status == .endOfStream || status == .error { finished = true }
        }
        if let readError { throw readError }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WavWriter.header(dataBytes: UInt32(clamping: bytesWritten)))
    }
}
