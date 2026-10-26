import AppKit
import SwiftUI

@main
struct AtaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore.shared
    @AppStorage(Pref.dockIcon) private var dockIcon = false
    @AppStorage(Pref.menuBarIcon) private var menuBarIcon = true

    /// Hidden only when the Dock icon is there instead; `Presence` keeps that
    /// invariant, and this reads it so the two settings can never leave Ata
    /// running with no icon anywhere.
    private var showsMenuBarIcon: Binding<Bool> {
        Binding(get: { !dockIcon || menuBarIcon }, set: { menuBarIcon = $0 })
    }

    var body: some Scene {
        MenuBarExtra(isInserted: showsMenuBarIcon) {
            PopoverView()
                .environmentObject(store)
                .environmentObject(store.setup)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Snapshots.requested {
            Snapshots.run()
            return
        }
        endStaleCopies()
        if Diagnostics.requested {
            Diagnostics.run()
            return
        }
        if Updater.commandLineRequested {
            Updater.shared.runFromCommandLine()
            return
        }
        Notifier.shared.setUp()
        Presence.apply()
        // Whatever app you are in, and whether or not the icon is reachable.
        Hotkey.reload { AppStore.shared.toggleRecording() }
        let store = AppStore.shared
        store.bootstrap()
        if !Pref.d.bool(forKey: Pref.onboarded) || !store.setup.ready {
            WindowManager.shared.showOnboarding()
        }
    }

    /// Opening Ata while it is already running — from Spotlight, the Dock, the
    /// Finder, or `open -a Ata` — shows its window. It used to do nothing at
    /// all, which left a menu bar icon the system had hidden as the only way in.
    /// This is the one route that works however the icons are set, so it is
    /// wired up whether or not Ata is in the Dock.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { WindowManager.shared.showMain() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only a live recording needs an asynchronous shutdown. Anything else
        // quits at once: replying later from a Task deadlocks when terminate()
        // itself was called from a Task — the updater does exactly that — and
        // left the old copy hung beside the new one after every update.
        guard AppStore.shared.phase == .recording else {
            LocalEngine.currentProcess?.terminate()
            return .terminateNow
        }
        Task { @MainActor in
            await AppStore.shared.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Ends any other copy of Ata running from this same app bundle — typically
    /// the pre-update copy, which Ata 2.1 and 2.2 left hung after updating.
    /// Two copies would also fight over the microphone and the meetings folder.
    private func endStaleCopies() {
        let me = NSRunningApplication.current
        guard let id = Bundle.main.bundleIdentifier else { return }
        // Compare resolved paths: URL equality trips over trailing slashes and /tmp vs /private/tmp.
        func resolved(_ url: URL?) -> String? { url?.resolvingSymlinksInPath().standardizedFileURL.path }
        let mine = resolved(Bundle.main.bundleURL)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
            where app.processIdentifier != me.processIdentifier && resolved(app.bundleURL) == mine {
            NSLog("Ata: ending a stale copy (pid \(app.processIdentifier))")
            // Ask first, so a healthy copy closes any recording properly; a pre-update
            // copy from 2.1/2.2 is hung mid-quit and never answers, so force it after a moment.
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if !app.isTerminated { app.forceTerminate() }
            }
        }
    }
}

/// Regular windows (welcome and settings), managed by hand so they always come to the front.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var onboarding: NSWindow?
    private var settings: NSWindow?
    private var main: NSWindow?
    private var meetings: [String: (window: NSWindow, model: MeetingModel, closing: NSObjectProtocol)] = [:]

    func showOnboarding() {
        onboarding = present(onboarding, title: L("Welcome to Ata")) {
            OnboardingView()
                .environmentObject(AppStore.shared)
                .environmentObject(AppStore.shared.setup)
        }
    }

    func closeOnboarding() {
        onboarding?.close()
    }

    /// Ata's own window: the same thing the menu bar shows, in a window you can
    /// reach from the Dock, from ⌘-Tab and from Spotlight.
    func showMain() {
        main = present(main, title: L("Ata"), size: NSSize(width: 350, height: 620)) {
            PopoverView()
                .environmentObject(AppStore.shared)
                .environmentObject(AppStore.shared.setup)
        }
    }

    func showSettings() {
        settings = present(settings, title: L("Ata Settings")) {
            SettingsView()
                .environmentObject(AppStore.shared)
                .environmentObject(AppStore.shared.setup)
        }
    }

    /// A meeting's own window, one per meeting. `play` starts the audio.
    func showMeeting(_ id: String, play: Bool = false) {
        if let open = meetings[id] {
            NSApp.activate(ignoringOtherApps: true)
            open.window.makeKeyAndOrderFront(nil)
            if play { open.model.player.play() }
            return
        }
        let model = MeetingModel(id: id)
        let w = present(nil, title: model.meeting?.title ?? L("Meeting"), size: NSSize(width: 600, height: 720),
                        resizable: true) {
            MeetingView(model: model)
                .environmentObject(AppStore.shared)
        }
        if let last = meetings.values.map({ $0.window }).last {
            w.setFrameTopLeftPoint(w.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        // Closing drops the view, which stops the audio and saves your notes.
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                             object: w, queue: .main) { _ in
            MainActor.assumeIsolated { WindowManager.shared.forgetMeeting(id) }
        }
        meetings[id] = (w, model, closing)
        if play { model.player.play() }
    }

    func closeMeeting(_ id: String) {
        meetings[id]?.window.close()
    }

    private func forgetMeeting(_ id: String) {
        guard let open = meetings.removeValue(forKey: id) else { return }
        NotificationCenter.default.removeObserver(open.closing)
        open.model.close()
        open.window.contentView = nil
    }

    private func present<V: View>(_ existing: NSWindow?, title: String, size: NSSize = NSSize(width: 520, height: 600),
                                  resizable: Bool = false, @ViewBuilder content: () -> V) -> NSWindow {
        if let existing {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.formUnion([.resizable, .miniaturizable]) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: style,
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content())
        // A resizable window takes only its minimum size from SwiftUI, or the
        // view's ideal size would pin the window at that size.
        if resizable { host.sizingOptions = [.minSize] }
        w.contentView = host
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return w
    }
}
