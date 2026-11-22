import SwiftUI

/// The logo: a rounded gradient square with a waveform.
struct AppGlyph: View {
    var size: CGFloat = 28
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.brand)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Theme.brandShadow, radius: size * 0.15, y: size * 0.05)
    }
}

/// Bar-style level meter.
struct LevelMeter: View {
    let level: Float
    let tint: Color
    private let bars = 22

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let on = Float(i) / Float(bars) < level
                Capsule()
                    .fill(on ? tint : Color.primary.opacity(0.08))
                    .frame(height: 6)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

struct PulsingDot: View {
    var color: Color = Theme.recordingSolid
    @State private var on = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.25)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// The big round record button in the menu. The drawing lives in `HeroRecordButton`.
struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        HeroRecordButton(size: 64, state: .idle, action: action)
            .help(L("Start recording (⌘R)"))
    }
}

/// One card: large radius, a faint fill, a hairline stroke. `padding` is
/// `Theme.Space.m` unless a row needs to sit tighter inside it.
struct Card<Content: View>: View {
    var padding: CGFloat
    private var content: Content

    init(padding: CGFloat = Theme.Space.m, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
    }
}

/// Small "ghost" button used in the footer and in rows.
struct GhostButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .ataFont(12, weight: .medium)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hover ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.secondary)
        .onHover { hover = $0 }
    }
}

/// Checklist row used in the welcome window and in Settings.
struct CheckRow<Trailing: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    var optional = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(ok ? Color.green.opacity(0.15) : (optional ? Color.secondary.opacity(0.12) : Theme.warning.opacity(0.15)))
                    .frame(width: 30, height: 30)
                Image(systemName: ok ? "checkmark" : (optional ? "bell" : "exclamationmark"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ok ? Color.green : (optional ? Color.secondary : Theme.warning))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).ataFont(13, weight: .semibold)
                Text(detail).ataFont(11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !ok { trailing }
        }
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.2), value: ok)
    }
}

/// The app's switch. Always the native `NSSwitch`, except while the snapshot
/// renderer runs: an app that is not frontmost gets grey "inactive" switches
/// from AppKit, which would make every setting in the README look off. There,
/// the same shape is drawn in the active colours instead.
struct AppSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        if Snapshots.rendering {
            HStack {
                configuration.label
                Spacer(minLength: 8)
                Capsule()
                    .fill(configuration.isOn ? Theme.accent : Color.primary.opacity(0.12))
                    .frame(width: 36, height: 16)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                            .padding(1.5)
                    }
            }
        } else {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

/// A symbol, a headline and a line of detail. The paywall and the iPhone
/// welcome step share it, so the two stay laid out the same way.
struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.meTint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title).font(.headline)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Info, warning, failure, success, or a marked moment. One chrome: kind colour
/// at 10% behind the row, the symbol in that colour, title at 12 pt semibold
/// (the headline size, a point smaller so a menu banner stays one line).
struct Banner<Trailing: View>: View {
    enum Kind: CaseIterable {
        case info, warning, danger, success, moment

        var color: Color {
            switch self {
            case .info: return Theme.accent
            case .warning: return Theme.warning
            case .danger: return Theme.danger
            case .success: return Color.green
            case .moment: return Theme.moment
            }
        }
    }

    /// A symbol, or the progress that stands in for one while an update runs.
    enum Mark {
        case symbol(String)
        case progress(Double?)
    }

    var kind: Kind
    var mark: Mark
    /// Already a `Text`, so a literal still localizes and a formatted string stays verbatim.
    var title: Text
    var detail: Text? = nil
    var action: (() -> Void)? = nil
    var showsChevron: Bool = false
    var dismiss: (() -> Void)? = nil
    /// Spoken name of the dismiss control. Already localized by the caller.
    var dismissLabel: String? = nil
    private var trailing: Trailing

    init(kind: Kind, mark: Mark, title: Text, detail: Text? = nil,
         action: (() -> Void)? = nil, showsChevron: Bool = false,
         dismiss: (() -> Void)? = nil, dismissLabel: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.kind = kind
        self.mark = mark
        self.title = title
        self.detail = detail
        self.action = action
        self.showsChevron = showsChevron
        self.dismiss = dismiss
        self.dismissLabel = dismissLabel
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Group {
                if let action {
                    Button(action: action) { row }
                        .buttonStyle(.plain)
                } else {
                    row
                }
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .ataFont(10, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(dismissLabel ?? L("Dismiss"))
                .accessibilityLabel(dismissLabel ?? L("Dismiss"))
            }
        }
        .padding(Theme.Space.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(kind.color.opacity(0.10))
        )
    }

    private var row: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            markView
            VStack(alignment: .leading, spacing: 1) {
                title
                    .ataFont(12, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    detail
                        .ataCaption()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.s)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .ataFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            trailing
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case .symbol(let name):
            Image(systemName: name)
                .ataHeadline()
                .foregroundStyle(kind.color)
        case .progress(let value):
            if let value {
                ProgressView(value: value).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

extension Banner where Trailing == EmptyView {
    init(kind: Kind, mark: Mark, title: Text, detail: Text? = nil,
         action: (() -> Void)? = nil, showsChevron: Bool = false,
         dismiss: (() -> Void)? = nil, dismissLabel: String? = nil) {
        self.init(kind: kind, mark: mark, title: title, detail: detail, action: action,
                  showsChevron: showsChevron, dismiss: dismiss, dismissLabel: dismissLabel) {
            EmptyView()
        }
    }
}

/// Uppercase section title. The string is already localized.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .ataLabel()
            .foregroundStyle(.secondary)
    }
}

/// Centered icon, title and message for a list with nothing to show.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: icon)
                .ataFont(28)
                .foregroundStyle(.secondary)
            Text(verbatim: title)
                .ataHeadline()
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(verbatim: message)
                    .ataCallout()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The round play control. Large is the meeting player (pause while it plays);
/// the smaller ones play a voice sample and show stop while that sample plays.
struct PlayButton: View {
    enum Size: CGFloat, CaseIterable {
        case small = 22
        case regular = 26
        case large = 38

        var points: CGFloat { rawValue }
    }

    var size: Size
    var tint: AnyShapeStyle
    var playing: Bool
    var enabled: Bool = true
    var action: () -> Void

    private var symbol: String {
        guard playing else { return "play.fill" }
        return size == .large ? "pause.fill" : "stop.fill"
    }

    private var glyph: CGFloat {
        switch size {
        case .small: return 9
        case .regular: return 10
        case .large: return 15
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .ataFont(glyph, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: size.points, height: size.points)
                .background(Circle().fill(enabled ? tint : AnyShapeStyle(Color.gray.opacity(0.4))))
                .contentShape(Circle())
                .modifier(PlayHitTarget(expand: size == .small))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The people rows need a 44 pt target on iPhone. The meeting player is already larger.
private struct PlayHitTarget: ViewModifier {
    let expand: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if expand {
            content.frame(width: 44, height: 44).contentShape(Rectangle())
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Status tile, title and category shared by the Mac menu row and the iPhone list.
/// Each list still draws its own line under the title.
struct MeetingRowContent<Detail: View>: View {
    let meeting: Meeting
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(meeting.title)
                        #if os(iOS)
                        .font(.headline)
                        #else
                        .ataFont(12, weight: .semibold)
                        #endif
                        .lineLimit(1)
                    CategoryTagView(category: meeting.categoryValue)
                }
                detail()
            }
        }
    }

    private var tile: some View {
        let mark = Self.statusMark(meeting)
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(mark.color.opacity(0.14))
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: mark.symbol)
                    .ataFont(12, weight: .semibold)
                    .foregroundStyle(mark.color)
            )
    }

    /// The tile for this meeting's status. The same symbols on both lists.
    static func statusMark(_ meeting: Meeting) -> (symbol: String, color: Color) {
        if meeting.isPlaceholder { return ("icloud.and.arrow.down", .secondary) }
        switch meeting.status {
        case .done: return ("doc.text.fill", Theme.accent)
        case .failed: return ("exclamationmark.triangle.fill", Theme.danger)
        case .recording: return ("record.circle.fill", Theme.recordingSolid)
        case .pending, .transcribing: return ("hourglass", Theme.queued)
        }
    }
}

/// Full-width capsule. The brand gradient and ink that stays readable on it.
struct PrimaryButtonStyle: ButtonStyle {
    /// 50 pt on iPhone, 32 pt on Mac: the capsule's height on each platform.
    static var height: CGFloat {
        #if os(iOS)
        50
        #else
        32
        #endif
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.accentInk)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .background(Capsule().fill(Theme.brand))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Same capsule as `PrimaryButtonStyle`, with a 6% fill and accent text.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: PrimaryButtonStyle.height)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// One capsule per step. The current one is 18 pt wide; the others are 6 pt,
/// the same thickness as `QuotaMeter`.
struct StepDots: View {
    var count: Int
    var current: Int

    /// Out-of-range values sit on the first or last dot. An empty row stays at 0.
    static func clampedIndex(count: Int, current: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(current, 0), count - 1)
    }

    var body: some View {
        let index = Self.clampedIndex(count: count, current: current)
        HStack(spacing: Theme.Space.xs) {
            ForEach(0..<max(count, 0), id: \.self) { item in
                Capsule()
                    .fill(item == index ? Theme.accent : Color.primary.opacity(0.2))
                    .frame(width: item == index ? 18 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The free-minutes bar. Accent until 80% of the allowance, warning from there.
struct QuotaMeter: View {
    var usedMinutes: Int
    var limitMinutes: Int

    static func showsWarning(usedMinutes: Int, limitMinutes: Int) -> Bool {
        guard limitMinutes > 0, usedMinutes > 0 else { return false }
        return usedMinutes * 5 >= limitMinutes * 4
    }

    static func fraction(usedMinutes: Int, limitMinutes: Int) -> Double {
        guard limitMinutes > 0, usedMinutes > 0 else { return 0 }
        return min(Double(usedMinutes) / Double(limitMinutes), 1)
    }

    static func fillColor(usedMinutes: Int, limitMinutes: Int) -> Color {
        showsWarning(usedMinutes: usedMinutes, limitMinutes: limitMinutes) ? Theme.warning : Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(L("%d of %d free minutes", max(usedMinutes, 0), max(limitMinutes, 0)))
                .ataCaption()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Self.fillColor(usedMinutes: usedMinutes, limitMinutes: limitMinutes))
                            .frame(width: max(0, proxy.size.width * Self.fraction(usedMinutes: usedMinutes, limitMinutes: limitMinutes)))
                    }
                }
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A price option. The caller computes `badge` from the product prices ("Save 46 %").
struct PlanCard: View {
    var title: String
    var price: String
    var detail: String
    var badge: String?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(verbatim: title)
                        .ataHeadline()
                    Spacer(minLength: Theme.Space.s)
                    if let badge {
                        Text(verbatim: badge)
                            .ataCaption()
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, Theme.Space.xs)
                            .background(Capsule().fill(Theme.accent))
                    }
                }
                Text(verbatim: price)
                    .ataTitle()
                Text(verbatim: detail)
                    .ataCaption()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    // Selected is a 2 pt accent stroke. Unselected keeps the card hairline.
                    .strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.06),
                                  lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The round record control shared by the menu (64 pt) and the iPhone (120 pt).
/// Idle draws a ring in `Theme.recordingSolid` at 25% that grows from 1 to 1.15
/// over 2.4 s. Reduce Motion and snapshot runs hold it still, at rest, so the
/// ring sits under the fill and the button looks as it did.
struct HeroRecordButton: View {
    /// Named `Phase` so it does not hide SwiftUI's `@State`.
    enum Phase: Equatable {
        case idle, busy, recording
    }

    var size: CGFloat
    var state: Phase
    var action: () -> Void

    #if os(macOS)
    @State private var hover = false
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    private static let breathDuration = 2.4
    private static let breathScale = 1.15

    static func animatesBreath(state: Phase, reduceMotion: Bool, renderingSnapshots: Bool) -> Bool {
        state == .idle && !reduceMotion && !renderingSnapshots
    }

    private var breathes: Bool {
        Self.animatesBreath(state: state, reduceMotion: reduceMotion, renderingSnapshots: Snapshots.rendering)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if state == .idle {
                    Circle()
                        .stroke(Theme.recordingSolid.opacity(0.25), lineWidth: ringWidth)
                        .frame(width: size - ringWidth, height: size - ringWidth)
                        .scaleEffect(breathes && expanded ? Self.breathScale : 1)
                }
                Circle()
                    .fill(Theme.recording)
                    .frame(width: size, height: size)
                    .shadow(color: Theme.recordingSolid.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
                glyph
            }
            .frame(width: size, height: size)
            .scaleEffect(hoverScale)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        #if os(macOS)
        .onHover { hover = $0 }
        .animation(reduceMotion || Snapshots.rendering
                   ? nil
                   : .spring(response: 0.25, dampingFraction: 0.7),
                   value: hover)
        #endif
        .onAppear { startBreath() }
        .onChange(of: breathes) { _, _ in startBreath() }
    }

    /// Repeats only while idle. Snapshot runs and Reduce Motion leave `expanded`
    /// false, so the ring stays at 1 and is covered by the fill.
    private func startBreath() {
        guard breathes else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { expanded = false }
            return
        }
        guard !expanded else { return }
        withAnimation(.easeInOut(duration: Self.breathDuration).repeatForever(autoreverses: true)) {
            expanded = true
        }
    }

    /// The phone button is 120 pt and the menu button is 64. The shadow stays
    /// what each of those drew before they shared this view.
    private var phoneSized: Bool { size >= 100 }

    private var ringWidth: CGFloat { max(size * 0.06, 1) }

    #if os(macOS)
    private var hoverScale: CGFloat { hover ? 1.05 : 1 }
    #else
    private var hoverScale: CGFloat { 1 }
    #endif

    private var shadowOpacity: Double {
        if phoneSized { return 0.35 }
        #if os(macOS)
        return hover ? 0.5 : 0.3
        #else
        return 0.3
        #endif
    }

    private var shadowRadius: CGFloat {
        if phoneSized { return 16 }
        #if os(macOS)
        return hover ? 14 : 8
        #else
        return 8
        #endif
    }

    private var shadowY: CGFloat { phoneSized ? 6 : 3 }

    /// White on the red fill. `Theme.accentInk` is near-black in dark mode, which
    /// would sink into this button.
    @ViewBuilder private var glyph: some View {
        if state == .recording {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(.white)
                .frame(width: size * 40 / 120, height: size * 40 / 120)
        } else if phoneSized {
            Image(systemName: "mic.fill")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.white)
        } else {
            Image(systemName: "mic.fill")
                .ataFont(24, weight: .semibold)
                .foregroundStyle(.white)
        }
    }
}

/// Header, scrolling step, pinned footer. Both onboardings share this chrome.
struct OnboardingScaffold<Content: View, Footer: View>: View {
    var step: Int
    var count: Int
    var back: (() -> Void)?
    private var content: Content
    private var footer: Footer

    init(step: Int, count: Int, back: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.step = step
        self.count = count
        self.back = back
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.vertical, Theme.Space.l)
            }
            footer
                .frame(maxWidth: .infinity)
                .padding(Theme.Space.xl)
        }
    }

    /// A hidden Back on the right keeps the dots centred, including on step one
    /// where the real Back is only there to hold the width.
    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            backButton
            Spacer(minLength: Theme.Space.s)
            StepDots(count: count, current: step)
            Spacer(minLength: Theme.Space.s)
            backButton
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
    }

    private var backButton: some View {
        Button(action: { back?() }) {
            Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(.plain)
        .opacity(back == nil ? 0 : 1)
        .accessibilityHidden(back == nil)
        .allowsHitTesting(back != nil)
    }
}
