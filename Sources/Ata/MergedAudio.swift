import CLame
import Foundation

/// The whole meeting as one file: both tracks mixed into a mono MP3 that any
/// player, phone or chat app opens.
///
/// The MP3 is always an extra file next to the tracks, never a replacement:
/// transcribing again and recognising voices both need the tracks apart.
enum MergedAudio {
    /// 48 kbps mono at 16 kHz: about 21 MB an hour, and clear for speech.
    static let kbps: Int32 = 48

    enum Failure: LocalizedError {
        case noAudio, encoder

        var errorDescription: String? {
            switch self {
            case .noAudio: return L("No audio was found for this meeting.")
            case .encoder: return L("The MP3 encoder could not start.")
            }
        }
    }

    /// Mixes `tracks` into one MP3 at `destination`.
    ///
    /// Writes to a `.partial` file first and moves it into place only when it
    /// is complete, so a failure never leaves a truncated MP3 behind — and
    /// never touches the tracks.
    static func write(tracks: [URL], to destination: URL) throws {
        guard !tracks.isEmpty else { throw Failure.noAudio }
        let readers = try tracks.map { try BlockReader(PCM16Reader($0)) }
        let encoder = try MP3Encoder(sampleRate: Int32(WavWriter.sampleRate), kbps: kbps)

        let fm = FileManager.default
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        fm.createFile(atPath: partial.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            let block = Int(PCM16Reader.blockFrames)
            while true {
                let mixed = try mix(readers.map { try $0.read(block) })
                if mixed.isEmpty { break }
                try handle.write(contentsOf: encoder.encode(mixed))
            }
            try handle.write(contentsOf: encoder.finish())
            try handle.close()

            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: partial)
            } else {
                try fm.moveItem(at: partial, to: destination)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// The meeting's tracks, mixed into `meeting.mp3` in its folder.
    static func write(_ meeting: Meeting) throws {
        try write(tracks: [meeting.micAudioURL, meeting.systemAudioURL].compactMap { $0 },
                  to: meeting.mergedAudioURL)
    }

    /// Meetings that have their tracks but no meeting.mp3 yet — everything
    /// recorded before Ata 2.4, oldest last. A meeting still recording is left alone.
    static func missing(in meetings: [Meeting]) -> [Meeting] {
        meetings.filter { $0.status != .recording && $0.hasAudio && !$0.hasMergedAudio }
    }

    /// Sample-by-sample sum, clamped so two loud voices at once clip instead
    /// of wrapping around into noise. A shorter track counts as silence.
    static func mix(_ tracks: [[Int16]]) -> [Int16] {
        let length = tracks.map(\.count).max() ?? 0
        guard length > 0 else { return [] }
        if tracks.count == 1 { return tracks[0] }
        var out = [Int16](repeating: 0, count: length)
        for i in 0..<length {
            var sum: Int32 = 0
            for t in tracks where i < t.count { sum += Int32(t[i]) }
            out[i] = Int16(clamping: sum)
        }
        return out
    }

    /// Hands out exactly `count` samples at a time (fewer only at the end),
    /// whatever block sizes the decoder produces, so the tracks stay in step.
    private final class BlockReader {
        private let reader: PCM16Reader
        private var pending: [Int16] = []
        private var done = false

        init(_ reader: PCM16Reader) { self.reader = reader }

        func read(_ count: Int) throws -> [Int16] {
            while pending.count < count, !done {
                if let next = try reader.next() { pending += next } else { done = true }
            }
            let n = min(count, pending.count)
            let out = Array(pending[..<n])
            pending.removeFirst(n)
            return out
        }
    }
}

/// A thin wrapper over LAME: mono 16-bit samples in, MP3 bytes out.
final class MP3Encoder {
    private let lame: OpaquePointer

    init(sampleRate: Int32, kbps: Int32) throws {
        guard let lame = lame_init() else { throw MergedAudio.Failure.encoder }
        lame_set_num_channels(lame, 1)
        lame_set_in_samplerate(lame, sampleRate)
        lame_set_out_samplerate(lame, sampleRate)
        lame_set_mode(lame, MONO)
        lame_set_VBR(lame, vbr_off)
        lame_set_brate(lame, kbps)
        lame_set_quality(lame, 2)
        // No Xing/LAME tag: it can only be filled in through a FILE*, and an
        // empty one makes players misread a constant-bitrate file's length.
        lame_set_bWriteVbrTag(lame, 0)
        lame_set_write_id3tag_automatic(lame, 0)
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            throw MergedAudio.Failure.encoder
        }
        self.lame = lame
    }

    deinit { lame_close(lame) }

    func encode(_ samples: [Int16]) throws -> Data {
        guard !samples.isEmpty else { return Data() }
        // LAME's documented worst case for the output buffer.
        var out = [UInt8](repeating: 0, count: samples.count * 5 / 4 + 7_200)
        let written = samples.withUnsafeBufferPointer { pcm in
            out.withUnsafeMutableBufferPointer { mp3 in
                lame_encode_buffer(lame, pcm.baseAddress, nil, Int32(samples.count),
                                   mp3.baseAddress, Int32(mp3.count))
            }
        }
        guard written >= 0 else { throw MergedAudio.Failure.encoder }
        return Data(out[..<Int(written)])
    }

    /// The last frames LAME was holding back.
    func finish() throws -> Data {
        var out = [UInt8](repeating: 0, count: 7_200)
        let written = out.withUnsafeMutableBufferPointer { mp3 in
            lame_encode_flush(lame, mp3.baseAddress, Int32(mp3.count))
        }
        guard written >= 0 else { throw MergedAudio.Failure.encoder }
        return Data(out[..<Int(written)])
    }
}
