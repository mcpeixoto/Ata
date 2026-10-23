import AppKit
import SwiftUI

/// Renders the real UI to PNG for the README: `Ata --snapshots <dir>`.
///
/// The views are hosted in offscreen windows and drawn with `cacheDisplay`, so
/// this needs no screen-recording permission and works on a CI runner. The
/// state comes from fixtures — a throwaway meetings folder and argument-domain
/// defaults set by `scripts/snapshots.sh` — so a screenshot can never show a
/// real meeting.
@MainActor
enum Snapshots {
    static var requested: Bool { CommandLine.arguments.contains("--snapshots") }

    /// True while snapshots are being drawn; see `AppSwitchStyle`.
    nonisolated(unsafe) static var rendering = false

    static func run() {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshots"),
              i + 1 < CommandLine.arguments.count else {
            FileHandle.standardError.write(Data("usage: Ata --snapshots <output dir>\n".utf8))
            exit(2)
        }
        let out = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // ATA_SNAPSHOT_NATIVE=1 keeps the real NSSwitch, to check the shipping
        // controls still lay out right after a UI change.
        rendering = ProcessInfo.processInfo.environment["ATA_SNAPSHOT_NATIVE"] != "1"
        Pref.registerDefaults()
        let store = AppStore.shared
        store.setup.applySnapshotFixture()

        for appearance in [Look.light, Look.dark] {
            // Idle menu, with the queue transcribing in the background.
            store.applySnapshotFixture(recordingApp: nil, elapsed: 0, mic: 0, system: 0,
                                       transcribingID: Fixture.transcribingID, progress: 0.62)
            let idle = render(PopoverView().environmentObject(store).environmentObject(store.setup),
                              width: 350, appearance: appearance)
            write(frame(idle, appearance), to: out, name: "menu-idle-\(appearance.name)")

            // The Insights tab, with eight weeks of made-up history.
            let insights = render(PopoverView(tab: .insights).environmentObject(store).environmentObject(store.setup),
                                  width: 350, appearance: appearance)
            write(frame(insights, appearance), to: out, name: "menu-insights-\(appearance.name)")

            // The People tab, with made-up voices.
            let people = render(PopoverView(tab: .people).environmentObject(store).environmentObject(store.setup),
                                width: 350, appearance: appearance)
            write(frame(people, appearance), to: out, name: "menu-people-\(appearance.name)")

            // Mid-meeting.
            store.applySnapshotFixture(recordingApp: "Zoom", elapsed: 23 * 60 + 14, mic: 0.64, system: 0.47,
                                       transcribingID: nil, progress: 0)
            let recording = render(PopoverView().environmentObject(store).environmentObject(store.setup),
                                   width: 350, appearance: appearance)
            write(frame(recording, appearance), to: out, name: "menu-recording-\(appearance.name)")

            store.applySnapshotFixture(recordingApp: nil, elapsed: 0, mic: 0, system: 0,
                                       transcribingID: nil, progress: 0)
            // A meeting's own window: its notes, and its transcript.
            for (tab, name) in [(MeetingView.Tab.notes, "notes"), (MeetingView.Tab.transcript, "transcript")] {
                let meeting = render(MeetingView(model: MeetingModel(id: Fixture.meetingID), tab: tab, height: 760)
                                        .environmentObject(store),
                                     width: 600, height: 760, appearance: appearance)
                write(frame(meeting, appearance), to: out, name: "meeting-\(name)-\(appearance.name)")
            }

            // Taller than the real window so the README shows every section
            // instead of a form cut off mid-scroll.
            let settings = render(SettingsView(height: 1680).environmentObject(store).environmentObject(store.setup),
                                  width: 540, height: 1680, appearance: appearance)
            write(frame(settings, appearance), to: out, name: "settings-\(appearance.name)")

            let onboarding = render(OnboardingView(height: 890).environmentObject(store).environmentObject(store.setup),
                                    width: 520, height: 890, appearance: appearance)
            write(frame(onboarding, appearance), to: out, name: "onboarding-\(appearance.name)")

            if appearance == .dark {
                // The hero banner, 2:1 so it doubles as the GitHub social preview.
                let banner = render(Banner(shot: Image(nsImage: recording)), width: 1280, height: 640,
                                    appearance: .dark, scale: 1)
                write(banner, to: out, name: "banner")
            }
        }
        exit(0)
    }

    // MARK: - Rendering

    struct Look: Equatable {
        let name: String
        let appearance: NSAppearance
        static let light = Look(name: "light", appearance: NSAppearance(named: .aqua)!)
        static let dark = Look(name: "dark", appearance: NSAppearance(named: .darkAqua)!)
        static func == (a: Look, b: Look) -> Bool { a.name == b.name }
    }

    /// Hosts a view in an offscreen window and draws it into an image.
    private static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil,
                                        appearance: Look, scale: CGFloat = 2) -> NSImage {
        let root = view
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            .environment(\.controlActiveState, .key)

        let host = NSHostingView(rootView: root)
        host.appearance = appearance.appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height ?? size.height))

        let window = SnapshotWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: host.frame.width,
                                                  height: host.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()

        // Let SwiftUI lay out and settle its first animation frame.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()

        let bounds = host.bounds
        let pixels = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width),
                                         pixelsHigh: Int(pixels.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        window.orderOut(nil)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// An offscreen window is never key, so AppKit would draw every switch and
    /// progress bar in its grey inactive state. Claiming to be key fixes that
    /// without activating the app or stealing focus from whatever you're doing.
    private final class SnapshotWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    /// Puts a screenshot on a soft brand-gradient backdrop with rounded corners
    /// and a shadow, the way it sits on screen.
    private static func frame(_ shot: NSImage, _ look: Look) -> NSImage {
        let pad: CGFloat = 48
        let size = NSSize(width: shot.size.width + pad * 2, height: shot.size.height + pad * 2)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            fatalError("bitmap")
        }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let dark = look == .dark
        let gradient = NSGradient(colors: dark
            ? [NSColor(red: 0.13, green: 0.10, blue: 0.30, alpha: 1), NSColor(red: 0.26, green: 0.10, blue: 0.34, alpha: 1)]
            : [NSColor(red: 0.86, green: 0.84, blue: 1.00, alpha: 1), NSColor(red: 0.95, green: 0.85, blue: 0.99, alpha: 1)])!
        gradient.draw(in: NSRect(origin: .zero, size: size), angle: -35)

        let rect = NSRect(x: pad, y: pad, width: shot.size.width, height: shot.size.height)
        let clip = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.22)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        shot.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(dark ? 0.10 : 0.6).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ image: NSImage, to dir: URL, name: String) {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode \(name)\n".utf8))
            exit(1)
        }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Fixtures

    enum Fixture {
        static let transcribingID = "fixture-slack"
        /// Has a summary, your notes and named voices; see make-fixtures.py.
        static let meetingID = "fixture-zoom"
    }

    /// The README hero: name, pitch, and the menu mid-recording.
    private struct Banner: View {
        let shot: Image

        var body: some View {
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.24),
                                        Color(red: 0.24, green: 0.09, blue: 0.33)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.45), .clear],
                               center: .init(x: 0.78, y: 0.45), startRadius: 10, endRadius: 520)

                HStack(alignment: .center, spacing: 56) {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 18) {
                            AppGlyph(size: 84)
                            Text("Ata")
                                .font(.system(size: 92, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        Text("Record and transcribe any meeting,\nright from your Mac's menu bar.")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineSpacing(4)
                            .fixedSize()
                        HStack(spacing: 10) {
                            chip("waveform", "Local Whisper")
                            chip("sparkles", "OpenAI")
                            chip("lock.fill", "Private by default")
                        }
                        HStack(spacing: 10) {
                            chip("globe", "Any app")
                            chip("arrow.triangle.2.circlepath", "Auto-updates")
                            chip("heart.fill", "Open source")
                        }
                    }
                    shot
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                }
                .padding(.horizontal, 72)
            }
            .frame(width: 1280, height: 640)
        }

        private func chip(_ symbol: String, _ title: String) -> some View {
            Label(title, systemImage: symbol)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
    }
}
