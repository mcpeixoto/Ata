import Foundation
@testable import Ata
import XCTest

/// Live chunks and a final pass can each have a whisper-cli. The registry is
/// what quitting and the call-priority change walk.
final class WhisperProcessTests: XCTestCase {
    func testAddRemoveAndAll() {
        let first = Process()
        let second = Process()
        defer {
            WhisperProcesses.remove(first)
            WhisperProcesses.remove(second)
        }
        WhisperProcesses.add(first, meeting: "one")
        WhisperProcesses.add(second, meeting: "two")
        let both = Set(WhisperProcesses.all().map { ObjectIdentifier($0) })
        XCTAssertTrue(both.contains(ObjectIdentifier(first)))
        XCTAssertTrue(both.contains(ObjectIdentifier(second)))

        WhisperProcesses.remove(first)
        let left = Set(WhisperProcesses.all().map { ObjectIdentifier($0) })
        XCTAssertFalse(left.contains(ObjectIdentifier(first)))
        XCTAssertTrue(left.contains(ObjectIdentifier(second)))
    }

    func testAddAndRemoveFromSeveralThreads() {
        let processes = (0..<80).map { _ in Process() }
        defer { for process in processes { WhisperProcesses.remove(process) } }
        DispatchQueue.concurrentPerform(iterations: processes.count) { i in
            WhisperProcesses.add(processes[i], meeting: "m\(i)")
            if i.isMultiple(of: 2) { WhisperProcesses.remove(processes[i]) }
        }
        let left = Set(WhisperProcesses.all().map { ObjectIdentifier($0) })
        for i in processes.indices {
            let id = ObjectIdentifier(processes[i])
            if i.isMultiple(of: 2) {
                XCTAssertFalse(left.contains(id))
            } else {
                XCTAssertTrue(left.contains(id))
            }
        }
    }
}
