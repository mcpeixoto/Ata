import AppKit
import SwiftUI

/// How the menu bar icon looks while recording: chosen in Settings → Menu bar.
enum MenuIcon {
    enum Symbol: String, CaseIterable, Identifiable {
        case dot, waveform, mic, glyph

        var id: String { rawValue }

        var systemName: String {
            switch self {
            case .dot: return "record.circle.fill"
            case .waveform: return "waveform"
            case .mic: return "mic.fill"
            case .glyph: return "waveform.circle.fill"
            }
        }

        var title: String {
            switch self {
            case .dot: return L("Record dot")
            case .waveform: return L("Waveform")
            case .mic: return L("Microphone")
            case .glyph: return "Ata"
            }
        }
    }

    enum Tint: String, CaseIterable, Identifiable {
        case monochrome, red, accent

        var id: String { rawValue }

        var title: String {
            switch self {
            case .monochrome: return L("Like the menu bar")
            case .red: return L("Red")
            case .accent: return L("Accent color")
            }
        }

        /// Nil keeps the icon a template image, drawn in the menu bar's own colour.
        var color: NSColor? {
            switch self {
            case .monochrome: return nil
            case .red: return .systemRed
            case .accent: return .controlAccentColor
            }
        }
    }

    struct Style: Equatable {
        var symbol: Symbol = .dot
        var tint: Tint = .monochrome
        var timer = true
        var pulse = false

        init(symbol: Symbol = .dot, tint: Tint = .monochrome, timer: Bool = true, pulse: Bool = false) {
            self.symbol = symbol
            self.tint = tint
            self.timer = timer
            self.pulse = pulse
        }

        /// Reads the raw preference values; anything unknown falls back to the default.
        init(symbol: String?, tint: String?, timer: Bool, pulse: Bool) {
            self.init(symbol: symbol.flatMap(Symbol.init(rawValue:)) ?? .dot,
                      tint: tint.flatMap(Tint.init(rawValue:)) ?? .monochrome,
                      timer: timer, pulse: pulse)
        }
    }

    /// One breath every `period` seconds, between 35% and full opacity. Driven
    /// by the recording clock that already ticks for the timer, so pulsing
    /// costs no timer of its own.
    static func pulseOpacity(at date: Date, period: Double = 1.6) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * phase))
    }

    /// The icon as an image the menu bar can show. A tinted icon is not a
    /// template, or the menu bar would paint over its colour.
    static func image(_ style: Style, opacity: Double = 1) -> NSImage {
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let color = style.tint.color {
            config = config.applying(.init(paletteColors: [color]))
        }
        let symbol = NSImage(systemSymbolName: style.symbol.systemName, accessibilityDescription: L("Recording"))?
            .withSymbolConfiguration(config) ?? NSImage()

        let image: NSImage
        if opacity >= 1 {
            image = symbol
        } else {
            image = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
                return true
            }
        }
        image.isTemplate = style.tint.color == nil
        return image
    }
}

/// The icon while recording, as the menu bar draws it.
struct RecordingMenuIcon: View {
    let style: MenuIcon.Style
    let date: Date

    var body: some View {
        let opacity = style.pulse ? MenuIcon.pulseOpacity(at: date) : 1
        Image(nsImage: MenuIcon.image(style, opacity: opacity))
            .renderingMode(style.tint.color == nil ? .template : .original)
    }
}
