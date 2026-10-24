@testable import Ata
import XCTest

/// AudioImport is shared with the iPhone, where a file shared from another app
/// arrives as a copy with a made-up name: the meeting takes the name and date
/// it had where it was shared from.
final class AudioImportTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FilesTests.setUp()  // temp meetings and support folders, never the real ones
    }

    private func wav(seconds: Double, at url: URL) throws {
        let samples = Int(seconds * WavWriter.sampleRate)
        var data = WavWriter.header(dataBytes: UInt32(samples * 2))
        data.append(Data((0..<samples * 2).map { UInt8(($0 * 5) & 0xFF) }))
        try data.write(to: url)
    }

    private func folder() throws -> URL {
        let dir = FilesTests.root.appendingPathComponent("audio-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testACopyIsNamedAndDatedAsTheOriginal() throws {
        let copy = try folder().appendingPathComponent("\(UUID().uuidString).wav")
        try wav(seconds: 1, at: copy)
        let recorded = Date(timeIntervalSince1970: 1_790_000_000)

        let m = try AudioImport.meeting(from: copy, named: "Call with Ana.m4a", at: recorded)
        XCTAssertEqual(m.app, "Call with Ana")
        XCTAssertEqual(m.startedAt, recorded)
        XCTAssertEqual(m.endedAt?.timeIntervalSince(recorded) ?? 0, 1, accuracy: 0.05)
        XCTAssertEqual(m.status, .pending)
        XCTAssertEqual(m.dir.deletingLastPathComponent().path, Paths.meetingsDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the copy is only read")
    }

    func testWithoutANameItIsTheFilesOwn() throws {
        let source = try folder().appendingPathComponent("Voice memo \(UUID().uuidString.prefix(6)).wav")
        try wav(seconds: 1, at: source)
        let made = AudioImport.recordedDate(of: source)

        let m = try AudioImport.meeting(from: source, named: nil, at: nil)
        XCTAssertEqual(m.app, AudioImport.label(for: source))
        XCTAssertEqual(m.startedAt.timeIntervalSince1970, made.timeIntervalSince1970, accuracy: 1)

        let blank = try AudioImport.meeting(from: source, named: "", at: nil)
        XCTAssertEqual(blank.app, AudioImport.label(for: source), "an empty name is no name")
    }

    func testTheNameIsMadeSafeForAFolder() throws {
        let copy = try folder().appendingPathComponent("x.wav")
        try wav(seconds: 1, at: copy)
        let m = try AudioImport.meeting(from: copy, named: "Team: weekly.m4a", at: Date())
        XCTAssertEqual(m.app, "Team- weekly")
        XCTAssertFalse(m.id.contains(":"))
    }

    func testRecordedDateIsTheEarliestTheFileKnows() throws {
        let source = try folder().appendingPathComponent("dated.wav")
        try wav(seconds: 1, at: source)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: source.path)
        XCTAssertEqual(AudioImport.recordedDate(of: source).timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1)
    }

    func testAFailedImportOfACopyLeavesNothingBehind() throws {
        let copy = try folder().appendingPathComponent("not-audio.wav")
        try Data("not audio".utf8).write(to: copy)
        let staged = Library.stagedIDs()
        XCTAssertThrowsError(try AudioImport.meeting(from: copy, named: "Broken \(UUID().uuidString.prefix(6)).m4a", at: Date()))
        XCTAssertEqual(Library.stagedIDs(), staged)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "not audio")
    }
}
