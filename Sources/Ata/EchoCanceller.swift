import Accelerate
import Foundation

/// Takes the other participants out of your microphone track before it is
/// transcribed.
///
/// Without headphones the Mac's speakers play the others and the microphone
/// hears them, so their words came out a second time as yours. Ata records what
/// the speakers played (the system track), so that echo can be predicted and
/// removed: per frequency, a least-squares estimate of the path from speaker to
/// microphone is subtracted, what is left of the echo is suppressed, and frames
/// that hold nothing but echo are silenced. With headphones there is no echo to
/// find, and the microphone is left exactly as recorded.
///
/// It runs after the recording, so it can look at the whole meeting: the delay
/// is measured every 10 s, and clock drift between the microphone and the
/// speakers (external speakers have their own clock) is measured and undone.
///
/// The constants were tuned on a reference implementation with real speech. Echo
/// went from 0 to 31–36 dB down while only the others spoke, and your own speech
/// stayed within 0.1 dB.
enum EchoCanceller {
    struct Result: Equatable {
        var blocks: Int
        var blocksCancelled: Int
        /// Median speaker-to-microphone delay over the blocks that had echo.
        var delayMs: Double
        /// Clock drift that was undone, in parts per million; 0 when none was needed.
        var driftPPM: Double
    }

    static let sampleRate = 16_000
    static let frame = 512
    static let hop = 256
    static let bins = frame / 2 + 1
    /// Frames per block: 10 s. Each block learns from itself and the block before.
    static let block = 625
    /// Longest delay looked for, in frames: 800 ms, enough for Bluetooth speakers.
    static let maxLag = 50
    /// Echo path length per frequency, in frames (~200 ms of room), starting
    /// `pre` frames before the measured delay.
    static let taps = 12
    static let pre = 2
    static let ridge = 1e-2
    static let overSubtraction: Float = 2
    static let gainFloor: Float = 0.05
    /// A frame is echo only when subtraction left less than this share of the echo.
    static let gateRatio: Float = 0.5
    static let gateFloor: Float = 0.01
    /// Frames either side of your speech that the gate keeps open.
    static let hold = 3
    /// Below this envelope correlation there is no echo to remove (headphones).
    static let minCorrelation = 0.35
    /// Speech band used to detect echo: 200 Hz – 4 kHz.
    static let lowBin = 200 * frame / sampleRate
    static let highBin = 4000 * frame / sampleRate

    // MARK: - Files

    /// Cleans `mic` against `reference` (both 16 kHz mono 16-bit WAV, as Ata
    /// records them) into a new WAV at `destination`.
    ///
    /// Returns nil, and writes nothing, when no echo was found. The input files
    /// are only read.
    static func clean(mic: URL, reference: URL, to destination: URL) throws -> Result? {
        let micData = try Data(contentsOf: mic, options: .alwaysMapped)
        let refData = try Data(contentsOf: reference, options: .alwaysMapped)
        let header = 44
        guard micData.count > header + 2, refData.count > header + 2 else { return nil }

        let fm = FileManager.default
        let first = destination.appendingPathExtension("partial")
        let second = destination.appendingPathExtension("drift")
        defer {
            try? fm.removeItem(at: first)
            try? fm.removeItem(at: second)
        }

        return try micData.withUnsafeBytes { (m: UnsafeRawBufferPointer) -> Result? in
            try refData.withUnsafeBytes { (r: UnsafeRawBufferPointer) -> Result? in
                let micSignal = Signal(pcm: m.baseAddress!.advanced(by: header).assumingMemoryBound(to: Int16.self),
                                       count: (micData.count - header) / 2)
                let refSignal = Signal(pcm: r.baseAddress!.advanced(by: header).assumingMemoryBound(to: Int16.self),
                                       count: (refData.count - header) / 2)

                let plain = try WavSink(first, samples: micSignal.count)
                let pass = try cancel(mic: micSignal, reference: refSignal) { try plain.write($0) }
                try plain.close()
                guard pass.cancelled > 0 else { return nil }

                var chosen = (url: first, pass: pass, slope: 0.0)
                let slope = drift(mic: micSignal, reference: refSignal)
                if abs(slope) >= 5e-6 {
                    var warped = refSignal
                    warped.slope = slope
                    let sink = try WavSink(second, samples: micSignal.count)
                    let corrected = try cancel(mic: micSignal, reference: warped) { try sink.write($0) }
                    try sink.close()
                    if corrected.residual < pass.residual { chosen = (second, corrected, slope) }
                }

                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: chosen.url, to: destination)
                return chosen.pass.result(driftPPM: chosen.slope * 1e6)
            }
        }
    }

    /// The same, in memory, for tests: the cleaned samples, or nil without echo.
    static func process(mic: [Float], reference: [Float]) -> (output: [Float], result: Result)? {
        let micSignal = Signal(mic)
        let refSignal = Signal(reference)
        var plain: [Float] = []
        plain.reserveCapacity(mic.count)
        let pass = cancel(mic: micSignal, reference: refSignal) { plain += $0 }
        guard pass.cancelled > 0 else { return nil }

        let slope = drift(mic: micSignal, reference: refSignal)
        if abs(slope) >= 5e-6 {
            var warped = refSignal
            warped.slope = slope
            var corrected: [Float] = []
            corrected.reserveCapacity(mic.count)
            let second = cancel(mic: micSignal, reference: warped) { corrected += $0 }
            if second.residual < pass.residual { return (corrected, second.result(driftPPM: slope * 1e6)) }
        }
        return (plain, pass.result(driftPPM: 0))
    }

    // MARK: - Signals

    /// Samples as floats in [-1, 1], zero outside the recording, optionally
    /// time-warped by `slope` to undo clock drift.
    struct Signal {
        let count: Int
        var slope: Double = 0
        private let pcm: UnsafePointer<Int16>?
        private let floats: [Float]

        init(_ floats: [Float]) {
            self.floats = floats
            pcm = nil
            count = floats.count
        }

        init(pcm: UnsafePointer<Int16>, count: Int) {
            self.pcm = pcm
            floats = []
            self.count = count
        }

        @inline(__always) private func raw(_ i: Int) -> Float {
            guard i >= 0, i < count else { return 0 }
            if let pcm { return Float(Int16(littleEndian: pcm[i])) / 32_768 }
            return floats[i]
        }

        @inline(__always) subscript(i: Int) -> Float {
            guard slope != 0 else { return raw(i) }
            let source = Double(i) - slope * Double(i)
            let i0 = Int(source.rounded(.down))
            let f = Float(source - Double(i0))
            return raw(i0) * (1 - f) + raw(i0 + 1) * f
        }
    }

    /// STFT frames `start ..< start + count`, frame-major: `[(t - start) * bins + k]`.
    struct Frames {
        var re: [Float]
        var im: [Float]
        let start: Int
        let count: Int

        init(start: Int, count: Int) {
            self.start = start
            self.count = count
            re = [Float](repeating: 0, count: count * EchoCanceller.bins)
            im = re
        }

        @inline(__always) func at(_ t: Int, _ k: Int) -> Int { (t - start) * EchoCanceller.bins + k }

        /// Speech-band energy of frame `t`.
        func energy(_ t: Int) -> Double {
            var sum = 0.0
            let base = at(t, 0)
            for k in EchoCanceller.lowBin..<EchoCanceller.highBin {
                sum += Double(re[base + k] * re[base + k] + im[base + k] * im[base + k])
            }
            return sum
        }
    }

    /// Unscaled complex FFT on split arrays: forward is e^(−i…), inverse e^(+i…).
    final class FFT {
        let size: Int
        private let log2n: vDSP_Length
        private let setup: FFTSetup

        init(size: Int) {
            precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
            self.size = size
            log2n = vDSP_Length(size.trailingZeroBitCount)
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func forward(_ re: inout [Float], _ im: inout [Float]) {
            run(&re, &im, FFTDirection(kFFTDirection_Forward))
        }

        func inverse(_ re: inout [Float], _ im: inout [Float]) {
            run(&re, &im, FFTDirection(kFFTDirection_Inverse))
        }

        private func run(_ re: inout [Float], _ im: inout [Float], _ direction: FFTDirection) {
            precondition(re.count == size && im.count == size)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, direction)
                }
            }
        }
    }

    /// Short-time Fourier transform with a periodic square-root Hann window:
    /// analysis and synthesis together sum to one at 50% overlap.
    final class STFT {
        private let fft = FFT(size: EchoCanceller.frame)
        private var re = [Float](repeating: 0, count: EchoCanceller.frame)
        private var im = [Float](repeating: 0, count: EchoCanceller.frame)
        let window: [Float] = (0..<EchoCanceller.frame).map {
            Float(sqrt(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(EchoCanceller.frame))))
        }

        /// Frame `t` covers samples `t·hop − hop ..< t·hop − hop + frame`.
        func frames(_ s: Signal, from t0: Int, to t1: Int) -> Frames {
            var out = Frames(start: t0, count: max(0, t1 - t0))
            let n = EchoCanceller.frame
            for t in t0..<t1 where t >= 0 {
                let first = t * EchoCanceller.hop - EchoCanceller.hop
                for i in 0..<n {
                    re[i] = s[first + i] * window[i]
                    im[i] = 0
                }
                fft.forward(&re, &im)
                let base = out.at(t, 0)
                for k in 0..<EchoCanceller.bins {
                    out.re[base + k] = re[k]
                    out.im[base + k] = im[k]
                }
            }
            return out
        }

        /// One frame's spectrum back to windowed samples, for overlap-add.
        func synthesize(re zr: ArraySlice<Float>, im zi: ArraySlice<Float>) -> [Float] {
            let n = EchoCanceller.frame
            let half = n / 2
            let r0 = zr.startIndex, i0 = zi.startIndex
            for k in 0...half {
                re[k] = zr[r0 + k]
                im[k] = (k == 0 || k == half) ? 0 : zi[i0 + k]
            }
            for k in 1..<half {
                re[n - k] = re[k]
                im[n - k] = -im[k]
            }
            fft.inverse(&re, &im)
            let scale = 1 / Float(n)
            return (0..<n).map { re[$0] * scale * window[$0] }
        }
    }

    // MARK: - Cancellation

    struct Pass {
        var residual = 0.0
        var cancelled = 0
        var blocks = 0
        var delays: [Int] = []

        func result(driftPPM: Double) -> Result {
            let sorted = delays.sorted()
            let median = sorted.isEmpty ? 0 : Double(sorted[sorted.count / 2])
            return Result(blocks: blocks, blocksCancelled: cancelled,
                          delayMs: median * Double(EchoCanceller.hop) * 1000 / Double(EchoCanceller.sampleRate),
                          driftPPM: driftPPM)
        }
    }

    /// One pass over the meeting. Hands the cleaned samples to `write` in order,
    /// a block at a time, so nothing larger than a block is held in memory.
    static func cancel(mic: Signal, reference: Signal, write: ([Float]) throws -> Void) rethrows -> Pass {
        let stft = STFT()
        let frameCount = (mic.count + hop - 1) / hop + 1
        var pass = Pass()

        // Overlap-add: `pending[i]` is output sample `flushed + i`.
        var pending = [Float](repeating: 0, count: frame)
        var flushed = 0

        var b0 = 0
        while b0 < frameCount {
            let b1 = min(frameCount, b0 + block)
            let w0 = max(0, b0 - block)
            let back = maxLag + taps + pre
            let y = stft.frames(mic, from: w0, to: b1)
            let x = stft.frames(reference, from: w0 - back, to: b1 + pre)
            pass.blocks += 1

            var zr = Array(y.re[y.at(b0, 0)...])
            var zi = Array(y.im[y.at(b0, 0)...])

            if let d = delay(y: y, x: x, from: w0, to: b1) {
                pass.cancelled += 1
                pass.delays.append(d)
                subtractEcho(y: y, x: x, window: w0..<b1, block: b0..<b1, delay: d, zr: &zr, zi: &zi)
            }

            // What is left where the reference speaks, to compare drift corrections.
            var refEnergy: [Double] = []
            for t in b0..<b1 { refEnergy.append(x.energy(t)) }
            let threshold = percentile(refEnergy, 60)
            for (i, e) in refEnergy.enumerated() where e > threshold {
                for k in lowBin..<highBin {
                    let j = i * bins + k
                    pass.residual += Double(zr[j] * zr[j] + zi[j] * zi[j])
                }
            }

            // Overlap-add this block's frames, then hand over every sample no later frame touches.
            for (i, t) in (b0..<b1).enumerated() {
                let samples = stft.synthesize(re: zr[(i * bins)..<((i + 1) * bins)],
                                              im: zi[(i * bins)..<((i + 1) * bins)])
                let first = t * hop - hop
                let needed = first + frame - flushed
                if needed > pending.count { pending += [Float](repeating: 0, count: needed - pending.count) }
                for n in 0..<frame where first + n >= flushed {
                    pending[first + n - flushed] += samples[n]
                }
            }
            let done = b1 == frameCount ? mic.count : min(mic.count, b1 * hop - hop)
            if done > flushed {
                let n = done - flushed
                try write(Array(pending[0..<n]))
                pending.removeFirst(n)
                flushed = done
            }
            b0 = b1
        }
        return pass
    }

    /// The lag, in frames, at which the microphone's envelope follows the
    /// reference's, or nil when it doesn't follow it at all (no echo).
    static func delay(y: Frames, x: Frames, from w0: Int, to b1: Int) -> Int? {
        let count = b1 - w0
        var ey = [Double](repeating: 0, count: count)
        var ex = [Double](repeating: 0, count: count)
        for i in 0..<count {
            ey[i] = log(y.energy(w0 + i) + 1e-10)
            ex[i] = log(x.energy(w0 + i) + 1e-10)
        }
        let floor = percentile(ex, 40)
        let active = ex.map { $0 > floor }

        var best = (r: -1.0, lag: 0)
        for lag in 0...maxLag {
            let n = count - lag
            guard n > 0 else { break }
            var a: [Double] = [], c: [Double] = []
            for i in 0..<n where active[i] {
                a.append(ey[lag + i])
                c.append(ex[i])
            }
            guard a.count >= 50, let r = pearson(a, c) else { continue }
            if r > best.r { best = (r, lag) }
        }
        return best.r >= minCorrelation ? best.lag : nil
    }

    /// Least-squares echo path per frequency over the window, subtracted from the
    /// block, then the residual suppressor and the echo-only gate.
    private static func subtractEcho(y: Frames, x: Frames, window: Range<Int>, block blockRange: Range<Int>,
                                     delay d: Int, zr: inout [Float], zi: inout [Float]) {
        let lo = d - pre
        let frames = blockRange.count
        var er = [Float](repeating: 0, count: frames * bins)
        var ei = er

        for k in 0..<bins {
            // r(m) = Σ conj(x(t−lo−m))·x(t−lo) and p(j) = Σ conj(x(t−lo−j))·y(t), over the window.
            var rr = [Double](repeating: 0, count: taps), ri = rr
            var pr = rr, pi = rr
            for t in window {
                let b = x.at(t - lo, k)
                let br = Double(x.re[b]), bi = Double(x.im[b])
                let yi = y.at(t, k)
                let yr = Double(y.re[yi]), yim = Double(y.im[yi])
                for m in 0..<taps {
                    let a = x.at(t - lo - m, k)
                    let ar = Double(x.re[a]), ai = Double(x.im[a])
                    // conj(a)·b
                    rr[m] += ar * br + ai * bi
                    ri[m] += ar * bi - ai * br
                    // conj(a)·y
                    pr[m] += ar * yr + ai * yim
                    pi[m] += ar * yim - ai * yr
                }
            }

            // Hermitian Toeplitz normal equations: A[i][j] = conj(r(j−i)) for j ≥ i, r(i−j) below.
            var ar = [Double](repeating: 0, count: taps * taps), ai = ar
            for i in 0..<taps {
                for j in 0..<taps {
                    if j >= i {
                        ar[i * taps + j] = rr[j - i]
                        ai[i * taps + j] = -ri[j - i]
                    } else {
                        ar[i * taps + j] = rr[i - j]
                        ai[i * taps + j] = ri[i - j]
                    }
                }
                ar[i * taps + i] += ridge * rr[0] + 1e-12
            }
            guard let h = solve(ar, ai, pr, pi, n: taps) else { continue }
            let hr = h.re, hi = h.im

            for (i, t) in blockRange.enumerated() {
                var sr = 0.0, si = 0.0
                for j in 0..<taps {
                    let a = x.at(t - lo - j, k)
                    let xr = Double(x.re[a]), xi = Double(x.im[a])
                    sr += hr[j] * xr - hi[j] * xi
                    si += hr[j] * xi + hi[j] * xr
                }
                er[i * bins + k] = Float(sr)
                ei[i * bins + k] = Float(si)
            }
        }

        var gate = [Bool](repeating: false, count: frames)
        for i in 0..<frames {
            var echo = 0.0, left = 0.0, heard = 0.0
            for k in 0..<bins {
                let j = i * bins + k
                let yr = zr[j], yi = zi[j]
                var r = yr - er[j], m = yi - ei[j]
                let pe = er[j] * er[j] + ei[j] * ei[j]
                let pz = r * r + m * m
                let gain = min(1, max(gainFloor, 1 - overSubtraction * pe / (pz + 1e-12)))
                r *= gain
                m *= gain
                zr[j] = r
                zi[j] = m
                if k >= lowBin && k < highBin {
                    echo += Double(pe)
                    left += Double(r * r + m * m)
                    heard += Double(yr * yr + yi * yi)
                }
            }
            gate[i] = echo > 0.3 * heard && left < Double(gateRatio) * echo
        }

        // Echo-only frames go quiet; your speech keeps the gate open around it.
        var keep = (0..<frames).map { !gate[$0] }
        let speech = keep
        for s in 1...hold {
            for i in 0..<frames {
                if i + s < frames && speech[i + s] { keep[i] = true }
                if i - s >= 0 && speech[i - s] { keep[i] = true }
            }
        }
        for i in 0..<frames where !keep[i] {
            for k in 0..<bins {
                zr[i * bins + k] *= gateFloor
                zi[i * bins + k] *= gateFloor
            }
        }
    }

    // MARK: - Drift

    /// The rate at which the microphone's delay changes over the meeting, as a
    /// fraction (−8e−5 is 80 ppm). Measured on 10 s chunks with GCC-PHAT, fitted
    /// robustly, and refined on the corrected reference up to three times.
    static func drift(mic: Signal, reference: Signal) -> Double {
        let chunk = 10 * sampleRate
        let maxLag = sampleRate * 8 / 10
        guard mic.count >= 4 * chunk else { return 0 }
        var size = 1
        while size < 2 * chunk { size *= 2 }
        let fft = FFT(size: size)

        var total = 0.0
        for _ in 0..<3 {
            var warped = reference
            warped.slope = total
            var points: [(t: Double, lag: Double)] = []
            var s = 0
            while s + chunk <= mic.count {
                if let lag = gccLag(mic: mic, reference: warped, start: s, length: chunk, maxLag: maxLag, fft: fft) {
                    points.append((Double(s + chunk / 2), lag))
                }
                s += chunk
            }
            guard points.count >= 4 else { break }
            var slopes: [Double] = []
            for i in 0..<points.count {
                for j in (i + 1)..<points.count {
                    slopes.append((points[j].lag - points[i].lag) / (points[j].t - points[i].t))
                }
            }
            let slope = median(slopes)
            guard abs(slope) >= 5e-6 else { break }
            total += slope
        }
        return total
    }

    /// GCC-PHAT lag of the microphone behind the reference in one chunk, with
    /// sub-sample refinement, or nil when the chunk has no clear peak.
    static func gccLag(mic: Signal, reference: Signal, start: Int, length: Int, maxLag: Int, fft: FFT) -> Double? {
        let n = fft.size
        var xr = [Float](repeating: 0, count: n), xi = xr
        var power = 0.0
        for i in 0..<length {
            let v = reference[start + i]
            xr[i] = v
            power += Double(v * v)
        }
        guard (power / Double(length)).squareRoot() >= 1e-3 else { return nil }
        var yr = [Float](repeating: 0, count: n), yi = yr
        for i in 0..<length { yr[i] = mic[start + i] }
        fft.forward(&yr, &yi)
        fft.forward(&xr, &xi)

        // Y·conj(X), whitened.
        var cr = [Float](repeating: 0, count: n), ci = cr
        for k in 0..<n {
            let r = yr[k] * xr[k] + yi[k] * xi[k]
            let i = yi[k] * xr[k] - yr[k] * xi[k]
            let mag = (r * r + i * i).squareRoot() + 1e-12
            cr[k] = r / mag
            ci[k] = i / mag
        }
        fft.inverse(&cr, &ci)

        // Lags −maxLag…maxLag; negative lags wrap to the end.
        let window = (-maxLag...maxLag).map { Double(cr[($0 + n) % n]) / Double(n) }
        var peak = 0
        for i in window.indices where window[i] > window[peak] { peak = i }
        let mean = window.reduce(0) { $0 + abs($1) } / Double(window.count)
        guard mean > 0, window[peak] / mean > 8 else { return nil }
        var frac = 0.0
        if peak > 0 && peak < window.count - 1 {
            let a = window[peak - 1], b = window[peak], c = window[peak + 1]
            let den = a - 2 * b + c
            if den != 0 { frac = 0.5 * (a - c) / den }
        }
        return Double(peak - maxLag) + frac
    }

    // MARK: - Small maths

    /// Linear-interpolated percentile, as numpy computes it.
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let pos = q / 100 * Double(s.count - 1)
        let i = Int(pos.rounded(.down))
        let f = pos - Double(i)
        return i + 1 < s.count ? s[i] + (s[i + 1] - s[i]) * f : s[i]
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices {
            let da = a[i] - ma, db = b[i] - mb
            sab += da * db
            saa += da * da
            sbb += db * db
        }
        guard saa > 0, sbb > 0 else { return nil }
        return sab / (saa * sbb).squareRoot()
    }

    /// Solves the complex system A·h = p (row-major, n×n) by Gaussian
    /// elimination with partial pivoting; nil when A is singular.
    static func solve(_ ar: [Double], _ ai: [Double], _ pr: [Double], _ pi: [Double], n: Int)
        -> (re: [Double], im: [Double])? {
        var ar = ar, ai = ai, br = pr, bi = pi
        for col in 0..<n {
            var pivot = col
            var best = 0.0
            for row in col..<n {
                let m = ar[row * n + col] * ar[row * n + col] + ai[row * n + col] * ai[row * n + col]
                if m > best { best = m; pivot = row }
            }
            guard best > 0 else { return nil }
            if pivot != col {
                for j in 0..<n {
                    ar.swapAt(col * n + j, pivot * n + j)
                    ai.swapAt(col * n + j, pivot * n + j)
                }
                br.swapAt(col, pivot)
                bi.swapAt(col, pivot)
            }
            let dr = ar[col * n + col], di = ai[col * n + col]
            let dd = dr * dr + di * di
            for row in (col + 1)..<n {
                // factor = A[row][col] / A[col][col]
                let nr = ar[row * n + col], ni = ai[row * n + col]
                let fr = (nr * dr + ni * di) / dd
                let fi = (ni * dr - nr * di) / dd
                for j in col..<n {
                    let cr = ar[col * n + j], ci = ai[col * n + j]
                    ar[row * n + j] -= fr * cr - fi * ci
                    ai[row * n + j] -= fr * ci + fi * cr
                }
                br[row] -= fr * br[col] - fi * bi[col]
                bi[row] -= fr * bi[col] + fi * br[col]
            }
        }
        var hr = [Double](repeating: 0, count: n), hi = hr
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sr = br[row], si = bi[row]
            for j in (row + 1)..<n {
                let cr = ar[row * n + j], ci = ai[row * n + j]
                sr -= cr * hr[j] - ci * hi[j]
                si -= cr * hi[j] + ci * hr[j]
            }
            let dr = ar[row * n + row], di = ai[row * n + row]
            let dd = dr * dr + di * di
            hr[row] = (sr * dr + si * di) / dd
            hi[row] = (si * dr - sr * di) / dd
        }
        return (hr, hi)
    }

    /// Writes Int16 samples behind a fixed WAV header.
    private final class WavSink {
        private let handle: FileHandle

        init(_ url: URL, samples: Int) throws {
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: WavWriter.header(dataBytes: UInt32(clamping: samples * 2)))
        }

        func write(_ samples: [Float]) throws {
            var data = Data(capacity: samples.count * 2)
            for v in samples {
                let s = Int16(clamping: Int((max(-1, min(1, v)) * 32_767).rounded()))
                withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
            }
            try handle.write(contentsOf: data)
        }

        func close() throws { try handle.close() }
    }
}
