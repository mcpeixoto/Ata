import AppKit
import SwiftUI

/// Renders the real UI to PNG for the README: `Ata --snapshots <dir>`.
///
/// `Ata --snapshots <dir> --site` writes the website set instead (hero, recording
/// popover, transcript and notes crops, banner) into that directory. The README
/// shots keep the path below unchanged.
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
        // A development folder, so iCloud shows as available and is never used.
        CloudSync.shared.start(isIdle: { false }, changed: {})

        if CommandLine.arguments.contains("--site") {
            runSite(out: out, store: store)
            exit(0)
        }

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

            // One voice open: a name to give it, and what else can be done to it.
            PeopleModel.shared.reload()
            let first = PeopleModel.shared.sections(query: "").first?.voices.first
            let opened = render(PopoverView(tab: .people, openPerson: first.map { .voice($0.id) })
                .environmentObject(store).environmentObject(store.setup),
                                width: 350, appearance: appearance)
            write(frame(opened, appearance), to: out, name: "menu-people-open-\(appearance.name)")

            // Choosing who that voice really is.
            let merging = render(PopoverView(tab: .people, mergingPerson: first)
                .environmentObject(store).environmentObject(store.setup),
                                 width: 350, appearance: appearance)
            write(frame(merging, appearance), to: out, name: "menu-people-merge-\(appearance.name)")

            // Ata's own window, where the list fills whatever size it is given.
            let window = render(PopoverView(tab: .people, inWindow: true)
                .environmentObject(store).environmentObject(store.setup),
                                width: 520, height: 620, appearance: appearance)
            write(frame(window, appearance), to: out, name: "window-people-\(appearance.name)")

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
                let model = MeetingModel(id: Fixture.meetingID)
                // Mid-playback, so the transcript shows the word being heard.
                model.player.applySnapshotPosition(10.4, duration: 58)
                let meeting = render(MeetingView(model: model, tab: tab, height: 760)
                                        .environmentObject(store),
                                     width: 600, height: 760, appearance: appearance)
                write(frame(meeting, appearance), to: out, name: "meeting-\(name)-\(appearance.name)")
            }

            // Taller than the real window so the README shows every section
            // instead of a form cut off mid-scroll.
            let settings = render(SettingsView(height: 2280).environmentObject(store).environmentObject(store.setup),
                                  width: 540, height: 2280, appearance: appearance)
            write(frame(settings, appearance), to: out, name: "settings-\(appearance.name)")

            // One per step. Plain `onboarding` stays the last step, for the README's links.
            for (step, name) in [(OnboardingStep.welcome, "welcome"), (.permissions, "permissions"),
                                 (.you, "you"), (.test, "test"), (.done, "done")] {
                let shot = render(OnboardingView(height: 620, previewStep: step)
                                    .environmentObject(store).environmentObject(store.setup),
                                  width: OnboardingView.width, height: 620, appearance: appearance)
                write(frame(shot, appearance), to: out, name: "onboarding-\(name)-\(appearance.name)")
                if step == .done { write(frame(shot, appearance), to: out, name: "onboarding-\(appearance.name)") }
            }

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

    // MARK: - Website

    /// The marketing set. Each piece is a real view from the README path
    /// (`render` / `frame`); only the composition around them is new.
    private static func runSite(out: URL, store: AppStore) {
        for appearance in [Look.light, Look.dark] {
            store.applySnapshotFixture(recordingApp: "Zoom", elapsed: 23 * 60 + 14, mic: 0.64, system: 0.47,
                                       transcribingID: nil, progress: 0)
            let popover = render(PopoverView().environmentObject(store).environmentObject(store.setup),
                                 width: 350, appearance: appearance)
            write(floatCard(popover, appearance, radius: 14), to: out, name: "site-recording-\(appearance.name)")

            // The menu-bar label's own text truncates when the offscreen host
            // proposes a narrow width. This is that recording branch, at its
            // real size: the record symbol and the elapsed time.
            let icon = renderClear(RecordingStatusItem().environmentObject(store), appearance: appearance)
            let meeting = meetingShot(store, tab: .transcript, width: 760, height: 760, appearance: appearance)
            write(hero(meeting: meeting, popover: popover, icon: icon, appearance: appearance),
                  to: out, name: "site-hero-\(appearance.name)")

            // Eight speaker rows, measured on the 600×760 transcript render:
            // the search field ends near 250pt and the last line ends near 648pt.
            let transcript = meetingShot(store, tab: .transcript, width: 600, height: 760, appearance: appearance)
            let names = crop(transcript, to: NSRect(x: 0, y: 250, width: 600, height: 400))
            write(floatCard(names, appearance, radius: 16), to: out, name: "site-names-\(appearance.name)")

            // Summary heading starts near 260pt; 520pt reaches the notes footer.
            let notesShot = meetingShot(store, tab: .notes, width: 600, height: 760, appearance: appearance)
            let notes = crop(notesShot, to: NSRect(x: 0, y: 228, width: 600, height: 520))
            write(floatCard(notes, appearance, radius: 16), to: out, name: "site-notes-\(appearance.name)")

            if appearance == .dark {
                let banner = render(Banner(shot: Image(nsImage: frame(popover, appearance))),
                                    width: 1280, height: 640, appearance: .dark, scale: 1)
                write(banner, to: out, name: "banner")
            }
        }
    }

    private static func meetingShot(_ store: AppStore, tab: MeetingView.Tab, width: CGFloat, height: CGFloat,
                                    appearance: Look) -> NSImage {
        let model = MeetingModel(id: Fixture.meetingID)
        model.player.applySnapshotPosition(10.4, duration: 58)
        return render(MeetingView(model: model, tab: tab, height: height).environmentObject(store),
                      width: width, height: height, appearance: appearance)
    }

    /// The menu-bar icon while recording, matching `MenuBarLabel` for the
    /// default style (record dot, elapsed time, no pulse).
    private struct RecordingStatusItem: View {
        @EnvironmentObject var store: AppStore

        var body: some View {
            HStack(spacing: 4) {
                RecordingMenuIcon(style: MenuIcon.Style(), date: store.now)
                Text(verbatim: store.elapsedText)
                    .font(.system(size: 13))
                    .monospacedDigit()
            }
            .fixedSize()
        }
    }

    /// Menu-bar icon only: the hosting window is cleared so the pixels around
    /// the symbol stay transparent and can sit on the fake menu bar.
    private static func renderClear<V: View>(_ view: V, appearance: Look) -> NSImage {
        let root = view
            .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.appearance = appearance.appearance
        // A wide first proposal, so the elapsed time is measured in full
        // instead of being ellipsized into the host's default width.
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        let size = NSSize(width: min(max(fitted.width, 16), 400), height: min(max(fitted.height, 12), 32))
        host.frame = NSRect(origin: .zero, size: size)

        let window = SnapshotWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width,
                                                         height: size.height),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.appearance
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.contentView = host
        window.orderFrontRegardless()

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
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

    /// Desktop: brand wash at low opacity over the page colour, a 24pt menu
    /// bar, the meeting window on the left, and the recording popover on the
    /// right. The popover hangs from the menu bar under an icon centred on it,
    /// and stays clear of the window so the transcript and waveform stay visible.
    private static func hero(meeting: NSImage, popover: NSImage, icon: NSImage, appearance: Look) -> NSImage {
        let size = NSSize(width: 1600, height: 1000)
        let dark = appearance == .dark
        let menu: CGFloat = 24
        let windowX: CGFloat = 150
        let windowTop: CGFloat = 110
        // Card shadows blur about 30pt. Keep the popover at least this far
        // right of the window, then pull it toward a right margin that matches
        // the window's left margin when there is room.
        let gap: CGFloat = 40
        let minPopX = windowX + meeting.size.width + gap
        let aligned = size.width - windowX - popover.size.width
        let popX = min(max(minPopX, aligned), size.width - popover.size.width)
        let popTop = menu

        return bitmap(size: size) {
            NSAppearance.current = appearance.appearance
            paintBackdrop(size, dark: dark)
            paintCard(meeting, in: topLeftRect(x: windowX, top: windowTop, width: meeting.size.width,
                                               height: meeting.size.height, canvas: size.height),
                      radius: 12, dark: dark)
            paintCard(popover, in: topLeftRect(x: popX, top: popTop, width: popover.size.width,
                                               height: popover.size.height, canvas: size.height),
                      radius: 14, dark: dark)
            paintMenuBar(size, dark: dark)
            let iconX = popX + (popover.size.width - icon.size.width) / 2
            let iconTop = max(0, (menu - icon.size.height) / 2)
            NSGraphicsContext.current?.imageInterpolation = .none
            icon.draw(in: topLeftRect(x: iconX, top: iconTop, width: icon.size.width,
                                      height: icon.size.height, canvas: size.height))
        }
    }

    /// `rect` is top-left origin. The eight transcript rows need ~400pt; the
    /// notes summary through the footer needs ~520pt.
    private static func crop(_ image: NSImage, to rect: NSRect) -> NSImage {
        bitmap(size: rect.size) {
            NSGraphicsContext.current?.imageInterpolation = .none
            let below = image.size.height - rect.origin.y - rect.height
            image.draw(in: NSRect(x: -rect.origin.x, y: -below,
                                  width: image.size.width, height: image.size.height))
        }
    }

    /// Rounded card and soft shadow on a clear canvas. Same shadow as `frame`,
    /// without the lavender backdrop.
    private static func floatCard(_ shot: NSImage, _ look: Look, radius: CGFloat) -> NSImage {
        let pad: CGFloat = 48
        let size = NSSize(width: shot.size.width + pad * 2, height: shot.size.height + pad * 2)
        return bitmap(size: size) {
            NSAppearance.current = look.appearance
            paintCard(shot, in: NSRect(x: pad, y: pad, width: shot.size.width, height: shot.size.height),
                      radius: radius, dark: look == .dark)
        }
    }

    private static func bitmap(size: NSSize, scale: CGFloat = 2, _ draw: () -> Void) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("bitmap") }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func topLeftRect(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat,
                                    canvas: CGFloat) -> NSRect {
        NSRect(x: x, y: canvas - top - height, width: width, height: height)
    }

    private static func paintBackdrop(_ size: NSSize, dark: Bool) {
        let rect = NSRect(origin: .zero, size: size)
        let base = dark
            ? NSColor(srgbRed: 0x14 / 255, green: 0x12 / 255, blue: 0x18 / 255, alpha: 1)
            : NSColor(srgbRed: 0xF4 / 255, green: 0xF2 / 255, blue: 0xF8 / 255, alpha: 1)
        base.setFill()
        rect.fill()
        // Brand stops, barely there, so the page colour stays the ground.
        let gradient = NSGradient(colors: [
            brandNS(ThemeTokens.brandFirst, dark ? 0.20 : 0.12),
            brandNS(ThemeTokens.brandMiddle, dark ? 0.07 : 0.04),
            brandNS(ThemeTokens.brandLast, dark ? 0.14 : 0.08),
        ])!
        gradient.draw(in: rect, angle: -35)
    }

    private static func brandNS(_ rgb: ThemeTokens.RGB, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }

    private static func paintMenuBar(_ size: NSSize, dark: Bool) {
        let bar = NSRect(x: 0, y: size.height - 24, width: size.width, height: 24)
        (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white.withAlphaComponent(0.78)).setFill()
        bar.fill()
        NSColor.black.withAlphaComponent(dark ? 0.40 : 0.10).setFill()
        NSRect(x: 0, y: bar.minY, width: size.width, height: 1).fill()
    }

    private static func paintCard(_ shot: NSImage, in rect: NSRect, radius: CGFloat, dark: Bool) {
        let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
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
        NSGraphicsContext.current?.imageInterpolation = .none
        clip.addClip()
        shot.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(dark ? 0.10 : 0.6).setStroke()
        clip.lineWidth = 1
        clip.stroke()
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
                        Text("Record any meeting from your Mac's menu bar.\nGet a transcript that knows who said what.")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineSpacing(4)
                            .fixedSize()
                        HStack(spacing: 10) {
                            chip("laptopcomputer", "On your Mac")
                            chip("person.wave.2.fill", "Knows who said what")
                            chip("video.slash", "No bot in the call")
                        }
                        .fixedSize(horizontal: true, vertical: true)
                        HStack(spacing: 10) {
                            chip("doc.text", "Plain files")
                            chip("sparkles", "Works with your agent")
                            chip("globe", "Any app")
                        }
                        .fixedSize(horizontal: true, vertical: true)
                    }
                    .fixedSize(horizontal: true, vertical: false)
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
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        }
    }
}
