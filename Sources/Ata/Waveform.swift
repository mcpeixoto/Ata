import Foundation

/// How loud you and the others were over time, for the meeting window's player.
///
/// One level per 50 ms per lane, on a −60…0 dBFS scale stored as a byte, so an
/// hour is about 140 KB. Kept in the meeting folder as `waveform.bin`; it is not
/// audio, so it stays when the audio is deleted.
struct Waveform: Equatable {
    static let bucketMs = 50
    static let floorDB = -60.0
    private static let magic = Data("ATAW".utf8)
    private static let version: UInt8 = 1

    /// Your microphone, cleaned of the others when it was computed during transcription.
    var me: [UInt8]
    var others: [UInt8]

    var count: Int { max(me.count, others.count) }

    /// Reads each track (WAV or m4a) once. A missing track becomes a silent lane.
    static func compute(mic: URL?, system: URL?) throws -> Waveform {
        var me = try mic.map(levels) ?? []
        var others = try system.map(levels) ?? []
        let n = max(me.count, others.count)
        me += [UInt8](repeating: 0, count: n - me.count)
        others += [UInt8](repeating: 0, count: n - others.count)
        return Waveform(me: me, others: others)
    }

    /// The level of every 50 ms of a track.
    static func levels(_ url: URL) throws -> [UInt8] {
        let reader = try PCM16Reader(url)
        let bucket = Int(WavWriter.sampleRate) * bucketMs / 1000
        var out: [UInt8] = []
        var sum = 0.0, n = 0
        while let block = try reader.next() {
            for s in block {
                let v = Double(s) / 32_768
                sum += v * v
                n += 1
                if n == bucket {
                    out.append(level(rms: (sum / Double(n)).squareRoot()))
                    sum = 0
                    n = 0
                }
            }
        }
        if n > 0 { out.append(level(rms: (sum / Double(n)).squareRoot())) }
        return out
    }

    /// −60 dBFS and below is 0, full scale is 255.
    static func level(rms: Double) -> UInt8 {
        let db = 20 * log10(max(rms, 1e-9))
        let x = (db - floorDB) / -floorDB
        return UInt8((min(1, max(0, x)) * 255).rounded())
    }

    // MARK: File

    /// "ATAW", a version byte, the bucket length (UInt16) and count (UInt32),
    /// little-endian, then your lane and the others' lane.
    func write(to url: URL) throws {
        var data = Self.magic
        data.append(Self.version)
        withUnsafeBytes(of: UInt16(Self.bucketMs).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(count).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: me)
        data.append(contentsOf: others)
        try Coordinated.write(data, to: url)
    }

    static func read(from url: URL) -> Waveform? {
        guard let data = try? Data(contentsOf: url), data.count >= 11,
              data.prefix(4) == magic, data[data.startIndex + 4] == version else { return nil }
        let bytes = [UInt8](data)
        let bucket = Int(bytes[5]) | Int(bytes[6]) << 8
        let n = Int(bytes[7]) | Int(bytes[8]) << 8 | Int(bytes[9]) << 16 | Int(bytes[10]) << 24
        guard bucket == bucketMs, bytes.count == 11 + 2 * n else { return nil }
        return Waveform(me: Array(bytes[11..<(11 + n)]), others: Array(bytes[(11 + n)...]))
    }
}
