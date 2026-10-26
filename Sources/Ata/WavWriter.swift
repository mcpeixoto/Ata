import AVFoundation

/// Writes one track as 16 kHz mono 16-bit WAV (Whisper's native format).
///
/// Designed never to lose a recording:
///  - accepts any input format and converts it; if the format changes mid-stream
///    (you plugged in AirPods), it builds a new converter and keeps writing the same file;
///  - fills gaps with silence, so the two tracks stay aligned in time;
///  - rewrites the WAV header every few seconds, so even if the app crashes or the
///    Mac loses power the file stays readable (and is repaired on next launch).
final class WavWriter: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                         channels: 1, interleaved: true)!

    let url: URL
    private let handle: FileHandle
    private let startHostSeconds: Double
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var frames: Int64 = 0
    private var lastHeaderUpdate = Date()
    private var closed = false
    private var _level: Float = 0
    private var _lastBufferAt = Date()
    private var _inputFormats: [String] = []

    init(url: URL, startHostSeconds: Double) throws {
        self.url = url
        self.startHostSeconds = startHostSeconds
        FileManager.default.createFile(atPath: url.path, contents: WavWriter.header(dataBytes: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    // MARK: State (thread-safe)

    /// Current level 0…1 for the UI meters.
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastBufferAt) > 0.5 ? 0 : _level
    }

    var lastBufferAt: Date { lock.lock(); defer { lock.unlock() }; return _lastBufferAt }

    /// Every input format this writer was handed, in the order it saw them.
    ///
    /// Kept because a recording that came out at the wrong speed is almost
    /// always a recording whose real format was not the one the engine
    /// reported — and by the time anyone notices, the buffers are long gone and
    /// the WAV is a valid WAV either way. This is the only trace left.
    var inputFormats: [String] { lock.lock(); defer { lock.unlock() }; return _inputFormats }
    var duration: Double { lock.lock(); defer { lock.unlock() }; return Double(frames) / Self.sampleRate }

    /// Treats now as the last buffer time (avoids false watchdog alarms right after a restart).
    func touch() { lock.lock(); _lastBufferAt = Date(); lock.unlock() }

    // MARK: Writing

    /// `hostSeconds`: host-clock time of the buffer's first sample, when known.
    func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double?) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }

        _level = Self.meterLevel(buffer)
        _lastBufferAt = Date()

        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.outFormat)
            converter?.downmix = true
            converterInput = buffer.format
            let described = "\(Int(buffer.format.sampleRate)) Hz × \(buffer.format.channelCount)"
            if _inputFormats.last != described { _inputFormats.append(described) }
        }
        guard let converter else { return }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.outFormat, frameCapacity: capacity) else { return }

        let fed = Flag()
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed.value = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return }

        // Keep the timeline aligned: if audio went missing (the mic restarted), pad with silence.
        if let t = hostSeconds {
            let target = Int64((t - startHostSeconds) * Self.sampleRate)
            let gap = target - frames
            if gap > Int64(Self.sampleRate / 10), gap < Int64(Self.sampleRate * 3600 * 8) {
                writeSilence(gap)
            }
        }

        let n = Int(out.frameLength)
        do {
            try handle.write(contentsOf: Data(bytes: samples[0], count: n * 2))
            frames += Int64(n)
        } catch {
            NSLog("Ata: could not write \(url.lastPathComponent): \(error)")
        }

        if Date().timeIntervalSince(lastHeaderUpdate) > 3 {
            updateHeader()
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        updateHeader()
        try? handle.synchronize()
        try? handle.close()
        closed = true
    }

    private func writeSilence(_ count: Int64) {
        let chunk = Int64(Self.sampleRate) // 1 s
        let zeros = Data(count: Int(chunk) * 2)
        var remaining = count
        while remaining > 0 {
            let n = min(remaining, chunk)
            try? handle.write(contentsOf: n == chunk ? zeros : Data(count: Int(n) * 2))
            frames += n
            remaining -= n
        }
    }

    private func updateHeader() {
        let dataBytes = UInt32(clamping: frames * 2)
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(dataBytes: dataBytes))
            try handle.seekToEnd()
        } catch {
            NSLog("Ata: could not update the WAV header: \(error)")
        }
        lastHeaderUpdate = Date()
    }

    // MARK: Utilities

    static func header(dataBytes: UInt32) -> Data {
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(36 &+ dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        str("data"); u32(dataBytes)
        return d
    }

    /// Repairs the header of a WAV left half-written (crash, power loss…).
    @discardableResult
    static func repairHeader(_ url: URL) -> Double {
        let size = Paths.fileSize(url)
        guard size > 44, let h = try? FileHandle(forUpdating: url) else { return 0 }
        let dataBytes = UInt32(clamping: (size - 44) / 2 * 2)
        try? h.seek(toOffset: 0)
        try? h.write(contentsOf: header(dataBytes: dataBytes))
        try? h.close()
        return Double(dataBytes) / 2 / sampleRate
    }

    /// Duration (s) from the file size.
    static func duration(of url: URL) -> Double {
        let size = Paths.fileSize(url)
        return size > 44 ? Double(size - 44) / 2 / sampleRate : 0
    }

    /// RMS of the first channel, mapped to a 0…1 scale (≈ -50 dB … 0 dB).
    private static func meterLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        let stride = buffer.stride
        var sum: Float = 0
        var i = 0
        while i < n {
            let v = ch[0][i * stride]
            sum += v * v
            i += 1
        }
        let rms = sqrt(sum / Float(max(n, 1)))
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 50) / 50))
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}
