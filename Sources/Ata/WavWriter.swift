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
    /// Samples that were audio, not the silence inserted to fill a gap.
    private var _contentFrames: Int64 = 0
    private var lastHeaderUpdate = Date()
    private var closed = false
    private var _level: Float = 0
    private var _peakLevel: Float = 0
    private var _lastBufferAt = Date()
    private var _inputFormats: [String] = []
    /// Host time of the previous buffer, and of the first and last. The pace of
    /// a capture is measured from these, before any silence is written.
    private var _previousHost: Double?
    private var _firstHost: Double?
    private var _lastHost: Double?
    /// Sum of host deltas and of claimed audio duration, over ordinary cycles
    /// only. A dropout (the tap going quiet for seconds) is not a cycle.
    private var _cycleHost: Double = 0
    private var _cycleAudio: Double = 0
    private var _correctedDelivery = false

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

    /// The loudest buffer since the recording started. A capture can deliver
    /// buffers forever and still hold nothing — a tap pointed at the wrong
    /// output is digital silence with perfect attendance — and only the peak
    /// tells that apart from a side that simply has not spoken yet.
    var peakLevel: Float { lock.lock(); defer { lock.unlock() }; return _peakLevel }

    /// Every input format this writer was handed, in the order it saw them.
    ///
    /// Kept because a recording that came out at the wrong speed is almost
    /// always a recording whose real format was not the one the engine
    /// reported — and by the time anyone notices, the buffers are long gone and
    /// the WAV is a valid WAV either way. This is the only trace left.
    var inputFormats: [String] { lock.lock(); defer { lock.unlock() }; return _inputFormats }
    var duration: Double { lock.lock(); defer { lock.unlock() }; return Double(frames) / Self.sampleRate }

    /// Audio actually received, with the silence used to fill gaps left out.
    var contentDuration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(_contentFrames) / Self.sampleRate
    }

    /// Host time from the first buffer to the last.
    var hostSpan: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let first = _firstHost, let last = _lastHost, last > first else { return nil }
        return last - first
    }

    /// How much audio ordinary callbacks carried, as a fraction of the time
    /// those callbacks covered. 1 means the format told the truth. 0.5 means
    /// every buffer held half of what the clock said it should — double speed,
    /// once the halves are laid end to end. Nil until a second of ordinary
    /// callbacks has been seen, so a recording's first moment isn't a verdict.
    var deliveryRatio: Double? {
        lock.lock(); defer { lock.unlock() }
        guard _cycleHost >= 1 else { return nil }
        return _cycleAudio / _cycleHost
    }

    /// Whether a buffer was rewritten at the rate its samples actually arrived.
    var correctedDelivery: Bool { lock.lock(); defer { lock.unlock() }; return _correctedDelivery }

    /// A write failed, usually because the disk is full. Meters keep moving either
    /// way, so nothing else would show that this audio is not being saved.
    var writeFailed: Bool { lock.lock(); defer { lock.unlock() }; return _writeFailed }

    /// Treats now as the last buffer time (avoids false watchdog alarms right after a restart).
    private var _writeFailed = false

    func touch() { lock.lock(); _lastBufferAt = Date(); lock.unlock() }

    // MARK: Writing

    /// `hostSeconds`: host-clock time of the buffer's first sample, when known.
    func append(_ buffer: AVAudioPCMBuffer, hostSeconds: Double?) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }

        _level = Self.meterLevel(buffer)
        if _level > _peakLevel { _peakLevel = _level }
        _lastBufferAt = Date()

        // Before the converter, and before any silence is inserted. A buffer
        // that holds half the frames the clock just advanced is audio at double
        // speed; padding the gap afterwards makes the file the right length and
        // hides it. Relabel those frames with the rate they actually came in.
        let buffer = paced(buffer, hostSeconds: hostSeconds)

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
            _contentFrames += Int64(n)
        } catch {
            _writeFailed = true
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

    /// The buffer to convert. Usually the one we were handed. When the frames
    /// in it don't fill the host time since the previous one — and that gap is
    /// one ordinary callback, not a dropout — a copy labelled with the rate the
    /// samples actually arrived at.
    private func paced(_ buffer: AVAudioPCMBuffer, hostSeconds: Double?) -> AVAudioPCMBuffer {
        guard let t = hostSeconds else { return buffer }
        if _firstHost == nil { _firstHost = t }
        _lastHost = t
        let previous = _previousHost
        _previousHost = t
        guard let previous else { return buffer }
        let dt = t - previous
        guard dt > 0.002, dt < 0.25 else { return buffer }
        _cycleHost += dt
        _cycleAudio += Double(buffer.frameLength) / buffer.format.sampleRate
        guard let fixed = DeliveryRate.corrected(frames: Int(buffer.frameLength),
                                                 claimedRate: buffer.format.sampleRate,
                                                 hostDelta: dt),
              let retagged = DeliveryRate.retag(buffer, sampleRate: fixed) else { return buffer }
        if !_correctedDelivery {
            _correctedDelivery = true
            NSLog("Ata: \(url.lastPathComponent) arrived at \(Int(fixed)) Hz while its format said "
                  + "\(Int(buffer.format.sampleRate)) — writing it at the rate the samples actually came in")
        }
        return retagged
    }

    private func writeSilence(_ count: Int64) {
        let chunk = Int64(Self.sampleRate) // 1 s
        let zeros = Data(count: Int(chunk) * 2)
        var remaining = count
        while remaining > 0 {
            let n = min(remaining, chunk)
            do {
                try handle.write(contentsOf: n == chunk ? zeros : Data(count: Int(n) * 2))
            } catch {
                // Counting it anyway would make the header promise audio that isn't there.
                _writeFailed = true
                return
            }
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

/// What to do when a callback's frames and the host clock disagree.
///
/// The two numbers come from different places: the frames from the buffer, the
/// clock from the time between callbacks. They disagree when the format stamped
/// on the buffer is not the rate the samples were captured at. The file can
/// still end up the right length, because the gap is filled with silence, and
/// then nothing about the file says the speech in it is running at double speed.
enum DeliveryRate {
    /// Half and double are the interleaved-frame mistake (2×). A third and
    /// triple are a 48 kHz claim over a 16 kHz Bluetooth hands-free clock.
    private static let factors: [Double] = [1.0 / 3.0, 0.5, 2, 3]

    /// A sample rate to convert `frames` at, or nil to keep `claimedRate`.
    ///
    /// `hostDelta` has to be one ordinary callback. A dropout — nothing for a
    /// second — is silence, not a wrong rate, and "correcting" it would stamp
    /// the next words with a nonsense rate.
    static func corrected(frames: Int, claimedRate: Double, hostDelta: Double) -> Double? {
        guard frames > 0, claimedRate > 0, hostDelta > 0.002, hostDelta < 0.25 else { return nil }
        let ratio = (Double(frames) / claimedRate) / hostDelta
        guard abs(ratio - 1) > 0.08 else { return nil }
        for factor in factors where abs(ratio - factor) / factor < 0.08 {
            let rate = claimedRate * factor
            if rate >= 8_000, rate <= 192_000 { return rate }
        }
        return nil
    }

    /// The same samples, labelled with a different rate. The buffer we are
    /// handed borrows its memory from the callback, so the relabelled one is a copy.
    static func retag(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard buffer.format.sampleRate > 0,
              abs(buffer.format.sampleRate - sampleRate) / buffer.format.sampleRate > 0.02,
              let format = AVAudioFormat(commonFormat: buffer.format.commonFormat,
                                         sampleRate: sampleRate,
                                         channels: buffer.format.channelCount,
                                         interleaved: buffer.format.isInterleaved),
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength)
        else { return nil }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let from = src[i].mData, let into = dst[i].mData else { return nil }
            let n = Int(src[i].mDataByteSize)
            guard n > 0, n <= Int(dst[i].mDataByteSize) else { return nil }
            into.copyMemory(from: from, byteCount: n)
        }
        return copy
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}
