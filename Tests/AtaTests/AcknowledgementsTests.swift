@testable import Ata
import XCTest

/// The settings row is the bundled NOTICE. A bundle without the file hides it.
final class AcknowledgementsTests: XCTestCase {
    func testABundledNoticeIsShownAndAMissingOneIsHidden() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-notice-empty-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(Acknowledgements.text(in: try XCTUnwrap(Bundle(url: empty))))

        let filled = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-notice-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: filled, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: filled) }
        try "LAME is LGPL.\n".write(to: filled.appendingPathComponent("NOTICE"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Acknowledgements.text(in: try XCTUnwrap(Bundle(url: filled))), "LAME is LGPL.\n")

        let blank = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-notice-blank-\(UUID().uuidString).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: blank, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: blank) }
        try " \n".write(to: blank.appendingPathComponent("NOTICE"), atomically: true, encoding: .utf8)
        XCTAssertNil(Acknowledgements.text(in: try XCTUnwrap(Bundle(url: blank))))
    }
}
