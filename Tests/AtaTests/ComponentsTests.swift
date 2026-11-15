import AppKit
import SwiftUI
import XCTest
@testable import Ata

/// Banner colours, play-button sizes, and the old hand-drawn banner chrome.
final class ComponentsTests: XCTestCase {
    private static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent() // AtaTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo

    func testBannerKindColours() {
        assertSame(Banner<EmptyView>.Kind.info.color, Theme.accent)
        assertSame(Banner<EmptyView>.Kind.warning.color, Theme.warning)
        assertSame(Banner<EmptyView>.Kind.danger.color, Theme.danger)
        assertSame(Banner<EmptyView>.Kind.success.color, Color.green)
        assertSame(Banner<EmptyView>.Kind.moment.color, Theme.moment)
    }

    func testPlayButtonSizes() {
        XCTAssertEqual(PlayButton.Size.small.points, 22)
        XCTAssertEqual(PlayButton.Size.regular.points, 26)
        XCTAssertEqual(PlayButton.Size.large.points, 38)
    }

    /// `Banner` draws its fill with `Theme.Radius.medium` (10) in Components.swift.
    /// PopoverView and MeetingView used to spell `RoundedRectangle(cornerRadius: 10`
    /// once per banner, and MeetingView once more around the notes editor. Those
    /// are `Banner` and `Card` now, so the literal is gone from both files.
    /// The stop glyph in the iPhone record button still uses that rectangle;
    /// it is not a banner, and it is not in these two files.
    func testHandMadeBannerChromeIsGone() throws {
        let files = ["Sources/Ata/PopoverView.swift", "Sources/Ata/MeetingView.swift"]
        var count = 0
        for relative in files {
            let source = try String(contentsOf: Self.repo.appending(path: relative), encoding: .utf8)
            count += source.components(separatedBy: "RoundedRectangle(cornerRadius: 10").count - 1
        }
        XCTAssertEqual(count, 0)
    }

    private func assertSame(_ a: Color, _ b: Color, file: StaticString = #filePath, line: UInt = #line) {
        let left = resolved(a)
        let right = resolved(b)
        XCTAssertEqual(left.red, right.red, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(left.green, right.green, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(left.blue, right.blue, accuracy: 0.02, file: file, line: line)
    }

    private func resolved(_ color: Color) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (ns.redComponent, ns.greenComponent, ns.blueComponent)
    }
}
