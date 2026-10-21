import AppKit
import SwiftUI

@main
struct AtaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        MenuBarExtra {
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
        if Updater.commandLineRequested {
            Updater.shared.runFromCommandLine()
            return
        }
        Notifier.shared.setUp()
        let store = AppStore.shared
        store.bootstrap()
        if !Pref.d.bool(forKey: Pref.onboarded) || !store.setup.ready {
            WindowManager.shared.showOnboarding()
        }
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

    func showSettings() {
        settings = present(settings, title: L("Ata Settings")) {
            SettingsView()
                .environmentObject(AppStore.shared)
                .environmentObject(AppStore.shared.setup)
        }
    }

    private func present<V: View>(_ existing: NSWindow?, title: String, @ViewBuilder content: () -> V) -> NSWindow {
        if let existing {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = title
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        return w
    }
}
