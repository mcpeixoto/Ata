@testable import Ata
import XCTest

/// Without headphones the microphone hears the speakers. These meetings are
/// built so the answer is known: the others' speech goes through a speaker
/// (soft clipping), a room and a delay into your microphone, next to your own
/// speech, and the canceller must take the first out and leave the second.
final class EchoCancellerTests: XCTestCase {
    static let rate = Double(EchoCanceller.sampleRate)

    // MARK: A synthetic meeting

    /// The same generator the thresholds below were measured with.
    struct LCG {
        var x: UInt32
        mutating func next() -> Double {
            x = 1_664_525 &* x &+ 1_013_904_223
            return Double(x) / 4_294_967_296
        }
    }

    static let vowels: [[Double]] = [[700, 1200, 2600], [300, 2300, 3000], [500, 900, 2400],
                                     [400, 1900, 2600], [600, 1700, 2500]]

    /// A voice-like signal: syllables of harmonics shaped by vowel formants.
    static func voice(f0: Double, seconds: Double, seed: UInt32) -> [Double] {
        var rng = LCG(x: seed)
        let n = Int(seconds * rate), syllable = Int(0.22 * rate), gap = Int(0.06 * rate)
        var out = [Double](repeating: 0, count: n)
        var i = 0
        while i + syllable <= n {
            let f = f0 * (0.85 + 0.3 * rng.next())
            let vowel = vowels[Int(rng.next() * Double(vowels.count)) % vowels.count]
            var amps: [Double] = []
            var h = 1
            while Double(h) * f < 7000 {
                let formant = vowel.reduce(0.05) { $0 + exp(-pow((Double(h) * f - $1) / 250, 2)) }
                amps.append(formant / Double(h))
                h += 1
            }
            var phase = 0.0
            for s in 0..<syllable {
                let t = Double(s) / rate
                phase += 2 * .pi * f * (1 + 0.03 * sin(2 * .pi * 5 * t)) / rate
                var v = 0.0
                for (k, a) in amps.enumerated() { v += a * sin(Double(k + 1) * phase) }
                let env = pow(sin(.pi * Double(s) / Double(syllable)), 2)
                out[i + s] = v * env
            }
            i += syllable + gap
        }
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Double(n)).squareRoot()
        return out.map { $0 / rms * 0.08 }
    }

    struct Meeting {
        var far: [Float]   // what the speakers played: the system track
        var mic: [Float]   // your microphone
        var near: [Float]  // you alone, for scoring
        let seconds: Int
    }

    /// Others at 1–11 s, 17–20.3 s and 24–27.6 s; you at 13–15.9 s, 19–23.2 s
    /// (talking over them until 20.3 s) and 29–31.9 s; repeated every 34 s.
    static func meeting(seconds: Int = 34, delay: Double = 0.06, echoDB: Double = -3,
                        headphones: Bool = false, driftPPM: Double = 0, seed: UInt32 = 7) -> Meeting {
        let n = seconds * Int(rate)
        var far = [Double](repeating: 0, count: n), near = far
        func put(_ track: inout [Double], _ x: [Double], at t: Double) {
            let start = Int(t * rate)
            for (i, v) in x.enumerated() where start + i < track.count { track[start + i] += v }
        }
        var k = 0
        while k + 33 < seconds {
            let s = seed &+ UInt32(k)
            put(&far, voice(f0: 120, seconds: 10, seed: s), at: Double(k) + 1)
            put(&near, voice(f0: 210, seconds: 2.9, seed: s &+ 100), at: Double(k) + 13)
            put(&far, voice(f0: 135, seconds: 3.3, seed: s &+ 200), at: Double(k) + 17)
            put(&near, voice(f0: 195, seconds: 4.2, seed: s &+ 300), at: Double(k) + 19)
            put(&far, voice(f0: 120, seconds: 3.6, seed: s &+ 400), at: Double(k) + 24)
            put(&near, voice(f0: 220, seconds: 2.9, seed: s &+ 500), at: Double(k) + 29)
            k += 34
        }

        var echo = [Double](repeating: 0, count: n)
        if !headphones {
            var speaker = far.map { tanh(3 * $0) / 3 }
            if driftPPM != 0 {
                // The speakers run on their own clock.
                let src = speaker
                speaker = (0..<n).map { i in
                    let p = Double(i) * (1 + driftPPM * 1e-6)
                    let i0 = Int(p)
                    guard i0 + 1 < n else { return 0 }
                    return src[i0] + (src[i0 + 1] - src[i0]) * (p - Double(i0))
                }
            }
            // A room: the direct path and 40 decaying reflections over 300 ms.
            var rng = LCG(x: seed)
            var taps: [(Int, Double)] = [(0, 1)]
            for _ in 0..<40 {
                let d = 1 + Int(rng.next() * 0.3 * rate)
                taps.append((d, (rng.next() * 2 - 1) * exp(-6.9 * (Double(d) / rate) / 0.35)))
            }
            let norm = taps.reduce(0) { $0 + $1.1 * $1.1 }.squareRoot()
            let lag = Int(delay * rate), gain = pow(10, echoDB / 20)
            for (d, a) in taps {
                let w = a / norm * gain
                for i in 0..<(n - d - lag) { echo[i + d + lag] += w * speaker[i] }
            }
        }
        var rng = LCG(x: seed &+ 999)
        let noise = pow(10, -55.0 / 20) * 1.7
        let mic = (0..<n).map { Float(near[$0] + echo[$0] + (rng.next() * 2 - 1) * noise) }
        return Meeting(far: far.map(Float.init), mic: mic, near: near.map(Float.init), seconds: seconds)
    }

    static let othersOnly = [(1.5, 10.5), (17.2, 18.8), (24.2, 27.4)]
    static let youOnly = [(13.2, 15.6), (20.6, 23.0), (29.2, 31.6)]
    static let bothTalking = (19.1, 20.2)

    struct Score {
        var echoRemovedDB: Double   // worst stretch where only the others speak
        var yourVoiceSDR: Double    // worst stretch where only you speak
        var bothTalkingLevelDB: Double
    }

    static func score(_ out: [Float], _ m: Meeting) -> Score {
        func range(_ a: Double, _ b: Double, _ k: Int) -> Range<Int> {
            Int((Double(k) + a) * rate)..<Int((Double(k) + b) * rate)
        }
        func power(_ x: [Float], _ r: Range<Int>) -> Double { r.reduce(0) { $0 + Double(x[$1] * x[$1]) } / Double(r.count) }
        func error(_ r: Range<Int>) -> Double { r.reduce(0) { $0 + Double((out[$1] - m.near[$1]) * (out[$1] - m.near[$1])) } / Double(r.count) }
        var removed = Double.infinity, sdr = Double.infinity
        var k = 0
        while k + 33 < m.seconds {
            for (a, b) in othersOnly {
                let r = range(a, b, k)
                removed = min(removed, 10 * log10(power(m.mic, r) / max(power(out, r), 1e-20)))
            }
            for (a, b) in youOnly {
                let r = range(a, b, k)
                sdr = min(sdr, 10 * log10(power(m.near, r) / max(error(r), 1e-20)))
            }
            k += 34
        }
        let both = range(bothTalking.0, bothTalking.1, 0)
        return Score(echoRemovedDB: removed, yourVoiceSDR: sdr,
                     bothTalkingLevelDB: 10 * log10(power(out, both) / power(m.near, both)))
    }

    // MARK: Building blocks

    func testTheFFTMatchesAPlainDFT() {
        let n = 16
        var rng = LCG(x: 3)
        let xr = (0..<n).map { _ in Float(rng.next() * 2 - 1) }, xi = (0..<n).map { _ in Float(rng.next() * 2 - 1) }
        var re = xr, im = xi
        let fft = EchoCanceller.FFT(size: n)
        fft.forward(&re, &im)
        for k in 0..<n {
            var sr = 0.0, si = 0.0
            for j in 0..<n {
                let a = -2 * Double.pi * Double(j * k) / Double(n)
                sr += Double(xr[j]) * cos(a) - Double(xi[j]) * sin(a)
                si += Double(xr[j]) * sin(a) + Double(xi[j]) * cos(a)
            }
            XCTAssertEqual(Double(re[k]), sr, accuracy: 1e-4)
            XCTAssertEqual(Double(im[k]), si, accuracy: 1e-4)
        }
        fft.inverse(&re, &im)
        for j in 0..<n {
            XCTAssertEqual(re[j] / Float(n), xr[j], accuracy: 1e-5, "inverse is unscaled: dividing by n gives the input back")
            XCTAssertEqual(im[j] / Float(n), xi[j], accuracy: 1e-5)
        }
    }

    func testAComplexSolveIsExact() throws {
        // A = [[2, i], [−i, 3]], h = [1 − i, 2] → p = A·h
        let ar = [2.0, 0, 0, 3], ai = [0.0, 1, -1, 0]
        let hr = [1.0, 2], hi = [-1.0, 0]
        var pr = [0.0, 0], pi = [0.0, 0]
        for i in 0..<2 {
            for j in 0..<2 {
                pr[i] += ar[i * 2 + j] * hr[j] - ai[i * 2 + j] * hi[j]
                pi[i] += ar[i * 2 + j] * hi[j] + ai[i * 2 + j] * hr[j]
            }
        }
        let h = try XCTUnwrap(EchoCanceller.solve(ar, ai, pr, pi, n: 2))
        for j in 0..<2 {
            XCTAssertEqual(h.re[j], hr[j], accuracy: 1e-12)
            XCTAssertEqual(h.im[j], hi[j], accuracy: 1e-12)
        }
        XCTAssertNil(EchoCanceller.solve([0, 0, 0, 0], [0, 0, 0, 0], [1, 1], [0, 0], n: 2), "singular")
    }

    func testPercentilesAndMediansMatchNumpy() {
        XCTAssertEqual(EchoCanceller.percentile([1, 2, 3, 4], 40), 2.2, accuracy: 1e-12)
        XCTAssertEqual(EchoCanceller.percentile([5], 60), 5)
        XCTAssertEqual(EchoCanceller.median([3, 1, 2]), 2)
        XCTAssertEqual(EchoCanceller.median([4, 1, 3, 2]), 2.5)
    }

    // MARK: The meeting

    func testTheOthersAreTakenOutOfYourMicrophoneAndYourVoiceIsKept() throws {
        let m = Self.meeting()
        let (out, result) = try XCTUnwrap(EchoCanceller.process(mic: m.mic, reference: m.far), "echo was found")
        XCTAssertEqual(out.count, m.mic.count)
        let s = Self.score(out, m)
        let raw = Self.score(m.mic, m)
        // Measured on the Python reference: 44 dB removed, your voice at 32 dB, −0.5 dB level.
        XCTAssertGreaterThan(s.echoRemovedDB, 25, "\(s)")
        XCTAssertGreaterThan(s.yourVoiceSDR, 25, "\(s)")
        XCTAssertEqual(s.bothTalkingLevelDB, 0, accuracy: 2, "your voice keeps its level when you talk over them: \(s)")
        XCTAssertLessThan(raw.echoRemovedDB, 0.5, "the raw microphone does carry the echo")
        XCTAssertEqual(result.blocksCancelled, result.blocks)
        XCTAssertEqual(result.delayMs, 60, accuracy: 50, "\(result)")
        XCTAssertEqual(result.driftPPM, 0)
    }

    func testWithHeadphonesTheMicrophoneIsLeftAlone() {
        let m = Self.meeting(headphones: true)
        XCTAssertNil(EchoCanceller.process(mic: m.mic, reference: m.far), "no echo, nothing to change")
    }

    func testALongDelayIsFound() throws {
        // Bluetooth speakers add a quarter of a second.
        let m = Self.meeting(delay: 0.25)
        let (out, result) = try XCTUnwrap(EchoCanceller.process(mic: m.mic, reference: m.far))
        let s = Self.score(out, m)
        XCTAssertGreaterThan(s.echoRemovedDB, 25, "\(s)")
        XCTAssertGreaterThan(s.yourVoiceSDR, 25, "\(s)")
        XCTAssertEqual(result.delayMs, 250, accuracy: 60, "\(result)")
    }

    func testClockDriftBetweenSpeakersAndMicrophoneIsUndone() throws {
        // External speakers on their own clock, 80 ppm fast, over two minutes.
        let m = Self.meeting(seconds: 120, driftPPM: 80)
        let (out, result) = try XCTUnwrap(EchoCanceller.process(mic: m.mic, reference: m.far))
        let s = Self.score(out, m)
        // Python reference: estimated −81 ppm, 45 dB removed.
        XCTAssertEqual(result.driftPPM, -80, accuracy: 12, "\(result)")
        XCTAssertGreaterThan(s.echoRemovedDB, 20, "\(s)")
        XCTAssertGreaterThan(s.yourVoiceSDR, 25, "\(s)")
    }

    // MARK: Files

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ata-echo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = WavWriter.header(dataBytes: UInt32(samples.count * 2))
        for v in samples {
            let s = Int16(clamping: Int((max(-1, min(1, v)) * 32_767).rounded()))
            withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }

    private func readWAV(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.dropFirst(44).withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
    }

    func testCleaningFilesWritesACleanCopyAndLeavesTheRecordingAlone() throws {
        let dir = try scratch()
        let m = Self.meeting()
        let mic = dir.appendingPathComponent("mic.wav"), system = dir.appendingPathComponent("system.wav")
        try writeWAV(m.mic, to: mic)
        try writeWAV(m.far, to: system)
        let before = try Data(contentsOf: mic)

        let out = dir.appendingPathComponent("mic.echo-cancelled.wav")
        let result = try XCTUnwrap(EchoCanceller.clean(mic: mic, reference: system, to: out))
        XCTAssertGreaterThan(result.blocksCancelled, 0)
        XCTAssertEqual(try Data(contentsOf: mic), before, "the recording is never changed")
        XCTAssertEqual(WavWriter.duration(of: out), WavWriter.duration(of: mic), accuracy: 0.001)

        let cleaned = try readWAV(out)
        XCTAssertGreaterThan(Self.score(cleaned, m).echoRemovedDB, 25)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".partial") || $0.hasSuffix(".drift") }
        XCTAssertEqual(leftovers, [], "no temporary files are left behind")
    }

    func testWithoutEchoNoFileIsWritten() throws {
        let dir = try scratch()
        let m = Self.meeting(headphones: true)
        let mic = dir.appendingPathComponent("mic.wav"), system = dir.appendingPathComponent("system.wav")
        try writeWAV(m.mic, to: mic)
        try writeWAV(m.far, to: system)
        let out = dir.appendingPathComponent("mic.echo-cancelled.wav")
        XCTAssertNil(try EchoCanceller.clean(mic: mic, reference: system, to: out))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testEmptyOrMissingTracksNeverCrash() throws {
        let dir = try scratch()
        let mic = dir.appendingPathComponent("mic.wav"), system = dir.appendingPathComponent("system.wav")
        try writeWAV([], to: mic)
        try writeWAV([0.1, -0.1, 0.2], to: system)
        XCTAssertNil(try EchoCanceller.clean(mic: mic, reference: system, to: dir.appendingPathComponent("out.wav")))
        XCTAssertThrowsError(try EchoCanceller.clean(mic: mic, reference: dir.appendingPathComponent("missing.wav"),
                                                     to: dir.appendingPathComponent("out.wav")))
    }

    // MARK: Real voices

    /// Real speech from the system voices, on the Mac this runs on.
    func testRealVoicesThroughTheSpeakersAreRemoved() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/say"), "needs macOS say")
        let dir = try scratch()
        func say(_ args: [String]) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        func speak(_ voice: String, _ text: String) throws -> [Float] {
            let aiff = dir.appendingPathComponent("\(voice).aiff"), wav = dir.appendingPathComponent("\(voice).wav")
            // A runner may not have every voice; the default one still makes the point.
            let spoke = try say(["-v", voice, "-o", aiff.path, text]) || say(["-o", aiff.path, text])
            try XCTSkipUnless(spoke, "say could not synthesise speech here")
            try AudioFiles.decodeToWAV(aiff, to: wav)
            return try readWAV(wav)
        }
        let them = try speak("Daniel", "Thanks everyone. The marketing site is ready, and the pricing page was "
                             + "approved by finance yesterday afternoon, so we are on track for the launch on Thursday. "
                             + "Legal still wants to read the new terms before we send the email to customers.")
        let you = try speak("Samantha", "Great. I will send the release notes tonight.")

        // Them from 0.5 s, you after they finish, with a second of silence around.
        let n = Int(0.5 * Self.rate) + them.count + you.count + Int(2 * Self.rate)
        var far = [Float](repeating: 0, count: n), near = far
        let theirStart = Int(0.5 * Self.rate), yourStart = theirStart + them.count + Int(Self.rate)
        for (i, v) in them.enumerated() { far[theirStart + i] = v }
        for (i, v) in you.enumerated() where yourStart + i < n { near[yourStart + i] = v }
        // Laptop speakers: soft clipping, 70 ms late, a few reflections, as loud as you.
        var mic = near
        let lag = Int(0.07 * Self.rate)
        for (d, a) in [(0, 0.7), (180, 0.25), (530, -0.15), (1210, 0.1), (2300, 0.05)] {
            for i in 0..<(n - lag - d) { mic[i + lag + d] += Float(a) * tanh(2 * far[i]) / 2 }
        }

        let (out, _) = try XCTUnwrap(EchoCanceller.process(mic: mic, reference: far))
        func power(_ x: [Float], _ r: Range<Int>) -> Double { r.reduce(0) { $0 + Double(x[$1] * x[$1]) } / Double(r.count) }
        let theirs = (theirStart + Int(0.5 * Self.rate))..<(theirStart + them.count)
        let yours = yourStart..<(yourStart + you.count)
        let removed = 10 * log10(power(mic, theirs) / max(power(out, theirs), 1e-20))
        let kept = 10 * log10(power(out, yours) / power(near, yours))
        XCTAssertGreaterThan(removed, 20, "echo removed while they speak")
        XCTAssertEqual(kept, 0, accuracy: 1.5, "your voice keeps its level")
    }
}
