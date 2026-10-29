import XCTest
@testable import Ata

final class ProcessWatchdogTests: XCTestCase {

    private func sleepProcess(_ seconds: Int) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["\(seconds)"]
        try p.run()
        return p
    }

    /// A process that never writes anything is wedged, however long it runs:
    /// the watchdog must stop it, or the one-at-a-time queue behind it waits
    /// forever.
    func testAQuietProcessIsStopped() throws {
        let watchdog = LocalEngine.ProcessWatchdog(limit: 0.1)
        let p = try sleepProcess(60)
        watchdog.watch(p)
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(p.isRunning, "a wedged process must be terminated")
        XCTAssertTrue(watchdog.didStall())
        watchdog.stop()
    }

    /// Output is life: a process that keeps writing is slow, not wedged, and
    /// must be left alone however long the file takes.
    func testAWorkingProcessIsLeftAlone() throws {
        let watchdog = LocalEngine.ProcessWatchdog(limit: 0.25)
        let p = try sleepProcess(60)
        watchdog.watch(p)
        let deadline = Date().addingTimeInterval(0.9)
        while Date() < deadline {
            watchdog.noteActivity()
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(p.isRunning, "a process making progress must not be stopped")
        XCTAssertFalse(watchdog.didStall())
        watchdog.stop()
        p.terminate()
    }
}
