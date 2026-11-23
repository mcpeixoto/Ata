import Foundation

/// How hard transcription may push the machine right now.
///
/// While a call is on (Ata is recording, or another app holds the microphone),
/// whisper used to take cores-2 threads at the same priority as the call app,
/// and the call stuttered. During a call it now gets half the performance
/// cores at utility priority; the call always wins.
enum TranscriptionLoad {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _callActive = false

    /// Set by the app whenever recording or meeting detection changes.
    static var callActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _callActive }
        set { lock.lock(); _callActive = newValue; lock.unlock() }
    }

    /// whisper never runs above utility: it is background work even when no
    /// call is on, and `.userInitiated` competed with whatever the user was doing.
    static let processQoS: QualityOfService = .utility

    static var threads: Int {
        threads(callActive: callActive, performanceCores: performanceCores,
                allCores: ProcessInfo.processInfo.activeProcessorCount)
    }

    static func threads(callActive: Bool, performanceCores: Int?, allCores: Int) -> Int {
        if callActive {
            let perf = performanceCores ?? max(1, allCores / 2)
            return max(2, perf / 2)
        }
        return max(4, allCores - 2)
    }

    /// Apple Silicon's performance cores (perflevel0); nil where the key is missing.
    static let performanceCores: Int? = {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 else { return nil }
        return Int(n)
    }()

    /// Meetings that ended this recently may still be transcribed during a
    /// call: it is the one the user is waiting on. Older ones wait for the call to end.
    static let waitingWindow: TimeInterval = 30 * 60

    /// Waits until no call is on. For heavy work nobody is waiting on (MP3,
    /// compression), which used to start right as the next call began.
    static func waitForQuiet(poll: TimeInterval = 20) async {
        while callActive && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
    }

    /// Whether the queue may start this meeting now.
    static func mayStart(_ m: Meeting, callActive: Bool, now: Date) -> Bool {
        guard callActive else { return true }
        let ended = m.endedAt ?? m.startedAt.addingTimeInterval(m.duration ?? 0)
        return now.timeIntervalSince(ended) < waitingWindow
    }
}
