import CoreGraphics
import ImageIO
import XCTest
@testable import Ata

/// Contrast, the brand stops measured off the app icon, and the colour spellings
/// the tokens replace. Nothing here draws a view.
final class ThemeTests: XCTestCase {
    private static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent() // AtaTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo

    /// Files that may still spell `.orange` because that orange means paused or a warning.
    /// Those call sites use `Theme.warning`, and the only `Color.orange` is in Theme.swift,
    /// so nothing else is on the list.
    private static let orangeAllowed: Set<String> = []

    func testAccentContrast() {
        let white = ThemeTokens.RGB(hex: 0xFFFFFF)
        let warm = ThemeTokens.RGB(hex: 0xF5F3F8)
        let ink = ThemeTokens.RGB(hex: 0x1C1C1E)
        let deep = ThemeTokens.RGB(hex: 0x16141C)
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.accentLight, white), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.accentLight, warm), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.accentDark, ink), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.accentDark, deep), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.accentInkLight, ThemeTokens.accentLight), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(ThemeTokens.accentInkDark, ThemeTokens.accentDark), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(white, ThemeTokens.recordingSolid), 3.0)
    }

    func testBrandStopsMatchTheAppIcon() throws {
        let icon = Self.repo.appending(path: "Resources/AppIcon.iconset/icon_512x512.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(icon as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let first = try pixel(image, xFraction: 0.20, yFraction: 0.20)
        let last = try pixel(image, xFraction: 0.80, yFraction: 0.80)
        assertNear(first, ThemeTokens.brandFirst)
        assertNear(last, ThemeTokens.brandLast)
    }

    func testNoLeftoverAccentPurpleOrOrange() throws {
        let accent = try NSRegularExpression(pattern: #"Color\.accentColor|(?<![A-Za-z])\.accentColor\b"#)
        let purple = try NSRegularExpression(pattern: #"Color\.purple\b"#)
        let orange = try NSRegularExpression(pattern: #"\.orange\b"#)
        var offenders: [String] = []
        for dir in ["Sources/Ata", "Sources/AtaiOS", "Sources/AtaWidgets"] {
            let root = Self.repo.appending(path: dir)
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = walker?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    let text = String(line)
                    let range = NSRange(text.startIndex..., in: text)
                    let where_ = "\(url.lastPathComponent):\(index + 1)"
                    if accent.firstMatch(in: text, range: range) != nil || purple.firstMatch(in: text, range: range) != nil {
                        offenders.append(where_)
                    }
                    let theme = url.lastPathComponent == "Theme.swift"
                    let allowed = Self.orangeAllowed.contains(url.lastPathComponent)
                    if !theme, !allowed, orange.firstMatch(in: text, range: range) != nil {
                        offenders.append(where_)
                    }
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    private func contrast(_ a: ThemeTokens.RGB, _ b: ThemeTokens.RGB) -> Double {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ rgb: ThemeTokens.RGB) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// One pixel, measured from the top-left of the image ImageIO decoded.
    private func pixel(_ image: CGImage, xFraction: Double, yFraction: Double) throws -> ThemeTokens.RGB {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let width = image.width
        let height = image.height
        let x = min(width - 1, Int(Double(width) * xFraction))
        let y = min(height - 1, Int(Double(height) * yFraction))
        let bpp = max(1, image.bitsPerPixel / 8)
        let offset = y * image.bytesPerRow + x * bpp
        let raw = CFDataGetBytePtr(data).advanced(by: offset)
        let alphaInfo = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
            ?? CGImageAlphaInfo.none
        let alphaFirst = alphaInfo == .premultipliedFirst || alphaInfo == .first || alphaInfo == .noneSkipFirst
        let premultiplied = alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
        let (r, g, b, a): (UInt8, UInt8, UInt8, UInt8)
        if alphaFirst {
            (a, r, g, b) = (raw[0], raw[1], raw[2], raw[3])
        } else if alphaInfo == CGImageAlphaInfo.none || alphaInfo == .noneSkipLast || bpp == 3 {
            (r, g, b, a) = (raw[0], raw[1], raw[2], 255)
        } else {
            (r, g, b, a) = (raw[0], raw[1], raw[2], raw[3])
        }
        let alpha = Double(a) / 255
        let scale = !premultiplied || alpha == 0 ? 1 : 1 / alpha
        return ThemeTokens.RGB(
            red: min(1, Double(r) / 255 * scale),
            green: min(1, Double(g) / 255 * scale),
            blue: min(1, Double(b) / 255 * scale)
        )
    }

    private func assertNear(_ sample: ThemeTokens.RGB, _ token: ThemeTokens.RGB,
                            file: StaticString = #filePath, line: UInt = #line) {
        func byte(_ unit: Double) -> Int { Int((unit * 255).rounded()) }
        let delta = max(abs(byte(sample.red) - byte(token.red)),
                        abs(byte(sample.green) - byte(token.green)),
                        abs(byte(sample.blue) - byte(token.blue)))
        XCTAssertLessThanOrEqual(
            delta, 12,
            "sampled \(byte(sample.red)),\(byte(sample.green)),\(byte(sample.blue)) against the stop",
            file: file, line: line)
    }
}
