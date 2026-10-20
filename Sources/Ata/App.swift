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
        Notifier.shared.setUp()
        let store = AppStore.shared
        store.bootstrap()
        if !Pref.d.bool(forKey: Pref.onboarded) || !store.setup.ready {
            WindowManager.shared.showOnboarding()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppStore.shared.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Janelas "normais" (boas-vindas e definições), geridas à mão para abrirem sempre à frente.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private var onboarding: NSWindow?
    private var settings: NSWindow?

    func showOnboarding() {
        onboarding = present(onboarding, title: "Bem-vindo à Ata") {
            OnboardingView()
                .environmentObject(AppStore.shared)
                .environmentObject(AppStore.shared.setup)
        }
    }

    func closeOnboarding() {
        onboarding?.close()
    }

    func showSettings() {
        settings = present(settings, title: "Definições da Ata") {
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
