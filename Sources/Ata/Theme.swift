import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The hex values behind `Theme`. Tests read these; nothing here is drawn.
struct ThemeTokens {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(hex: UInt32) {
            red = Double((hex >> 16) & 0xFF) / 255
            green = Double((hex >> 8) & 0xFF) / 255
            blue = Double(hex & 0xFF) / 255
        }

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    }

    static let brandFirst = RGB(hex: 0x8B6CF9)
    static let brandMiddle = RGB(hex: 0xA552F3)
    static let brandLast = RGB(hex: 0xD24CBE)
    static let accentLight = RGB(hex: 0x8338E0)
    static let accentDark = RGB(hex: 0xB98CFF)
    static let accentInkLight = RGB(hex: 0xFFFFFF)
    static let accentInkDark = RGB(hex: 0x16141C)
    static let recordingSolid = RGB(hex: 0xF0365A)
    static let moment = RGB(hex: 0xE8A200)
    static let brandShadow = RGB(hex: 0xA552F3)
}

/// Colour, corner radii and spacing for the Mac and the iPhone.
enum Theme {
    static let brand = LinearGradient(
        colors: [ThemeTokens.brandFirst.color, ThemeTokens.brandMiddle.color, ThemeTokens.brandLast.color],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let accent = dynamic(ThemeTokens.accentLight, ThemeTokens.accentDark)
    /// Text drawn on an accent fill.
    static let accentInk = dynamic(ThemeTokens.accentInkLight, ThemeTokens.accentInkDark)

    /// The record button's gradient, top to bottom.
    static let recording = LinearGradient(
        colors: [Color(red: 1.0, green: 0.36, blue: 0.36),
                 Color(red: 0.92, green: 0.18, blue: 0.42)],
        startPoint: .top, endPoint: .bottom)
    /// The name the record button already uses.
    static let record = recording
    static let recordingSolid = ThemeTokens.recordingSolid.color

    /// Failures only.
    static let danger = Color.red
    /// Paused, and other warnings.
    static let warning = Color.orange

    static let moment = ThemeTokens.moment.color
    static let queued = Color.secondary

    static let meTint = Color(red: 0.40, green: 0.55, blue: 1.0)
    static let me = meTint
    static let othersTint = Color(red: 0.25, green: 0.82, blue: 0.62)
    static let others = othersTint

    /// `#A552F3` at 35%, the shadow under the glyph.
    static let brandShadow = ThemeTokens.brandShadow.color.opacity(0.35)

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    #if os(macOS)
    /// The menu bar paints an `NSColor`. Same sRGB as `recordingSolid`.
    static var recordingSolidNSColor: NSColor {
        let c = ThemeTokens.recordingSolid
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
    #endif
}

private func dynamic(_ light: ThemeTokens.RGB, _ dark: ThemeTokens.RGB) -> Color {
    #if os(macOS)
    let ns = NSColor(name: nil, dynamicProvider: { appearance in
        let night = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let c = night ? dark : light
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    })
    return Color(nsColor: ns)
    #elseif os(iOS)
    let ui = UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
    return Color(uiColor: ui)
    #else
    return light.color
    #endif
}
