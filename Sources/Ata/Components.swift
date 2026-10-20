import SwiftUI

enum Theme {
    static let brand = LinearGradient(colors: [Color(red: 0.40, green: 0.33, blue: 0.98),
                                               Color(red: 0.70, green: 0.32, blue: 0.95)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let record = LinearGradient(colors: [Color(red: 1.0, green: 0.36, blue: 0.36),
                                                Color(red: 0.92, green: 0.18, blue: 0.42)],
                                       startPoint: .top, endPoint: .bottom)
    static let meTint = Color(red: 0.40, green: 0.55, blue: 1.0)
    static let othersTint = Color(red: 0.25, green: 0.82, blue: 0.62)
}

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
            .shadow(color: Color.purple.opacity(0.35), radius: size * 0.15, y: size * 0.05)
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
    var color: Color = .red
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

/// The big round record button.
struct RecordButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 64, height: 64)
                    .shadow(color: .red.opacity(hover ? 0.5 : 0.3), radius: hover ? 14 : 8, y: 3)
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .scaleEffect(hover ? 1.05 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(L("Start recording (⌘R)"))
    }
}

/// Card with a translucent background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
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
                    .fill(ok ? Color.green.opacity(0.15) : (optional ? Color.secondary.opacity(0.12) : Color.orange.opacity(0.15)))
                    .frame(width: 30, height: 30)
                Image(systemName: ok ? "checkmark" : (optional ? "bell" : "exclamationmark"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ok ? Color.green : (optional ? Color.secondary : Color.orange))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
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
                    .fill(configuration.isOn ? Color.accentColor : Color.primary.opacity(0.12))
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
