import SwiftUI

/// Type for the views the Mac and the iPhone share (the meeting, People,
/// Insights). They are laid out in Mac points, 9–13 pt, which on a Mac is
/// exactly what they draw. On the iPhone the same sizes follow the Text Size
/// setting, and never start below 11 pt, the smallest size iOS text is meant
/// to be read at.
extension View {
    func ataFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        #if os(iOS)
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
        #else
        font(.system(size: size, weight: weight, design: design))
        #endif
    }

    /// The faintest text in the shared views: `.tertiary` on the Mac, where it
    /// reads fine, and `.secondary` on the iPhone, where 11 pt `.tertiary` in
    /// dark mode is barely visible.
    func ataFaint() -> some View {
        #if os(iOS)
        foregroundStyle(.secondary)
        #else
        foregroundStyle(.tertiary)
        #endif
    }
}

enum ScaledType {
    /// The smallest size the iPhone starts from.
    static let iOSMinimum: CGFloat = 11

    /// The size the iPhone starts from at the default Text Size.
    static func iOSBase(_ size: CGFloat) -> CGFloat { max(size, iOSMinimum) }

    /// The text style whose growth a fixed size follows: each size grows like
    /// the iOS style nearest to it, so small captions grow less than body text.
    static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: return .caption2   // 11
        case ..<12.5: return .caption    // 12
        case ..<14: return .footnote     // 13
        case ..<15.5: return .subheadline // 15
        case ..<16.5: return .callout    // 16
        case ..<19: return .body         // 17
        case ..<21: return .title3       // 20
        case ..<25: return .title2       // 22
        default: return .title
        }
    }
}

#if os(iOS)
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: ScaledType.iOSBase(size), relativeTo: ScaledType.style(for: size))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}
#endif
