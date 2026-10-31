import AppKit

/// Where Ata can be found: a menu bar icon, a Dock icon, or both.
///
/// Ata ships as a menu bar app (`LSUIElement`), which is right until the menu
/// bar is full. macOS gives an app no say in where its icon sits or whether it
/// is shown at all — the system drops the ones that don't fit, starting from
/// the left of the clock, and only the user can reorder them by ⌘-dragging. So
/// an icon that cannot be reached cannot be fixed from inside the app, and the
/// way out is to be somewhere else as well: in the Dock, in ⌘-Tab, and in
/// Spotlight.
///
/// Opening Ata when it is already running is handled too
/// (`applicationShouldHandleReopen`), so ⌘-Space, "Ata", Return brings its
/// window up whether or not any icon is visible. That path works even with both
/// icons hidden, which is why it is wired up before either of them.
@MainActor
enum Presence {
    static var showsDockIcon: Bool { Pref.d.bool(forKey: Pref.dockIcon) }

    /// The menu bar icon stays unless the Dock icon is there to replace it:
    /// Ata with neither is a running app with no way in but Spotlight, and
    /// nothing in the UI should be able to leave it there.
    static var showsMenuBarIcon: Bool {
        menuBarIconShows(dock: showsDockIcon, menuBar: Pref.d.bool(forKey: Pref.menuBarIcon))
    }

    /// The rule on its own: the menu bar icon is hidden only when the Dock icon
    /// is there instead.
    static func menuBarIconShows(dock: Bool, menuBar: Bool) -> Bool { !dock || menuBar }

    /// The policy when nothing is asking Ata to be a Dock app. Closing the
    /// last window uses this: a window that was key can leave a Dock icon
    /// behind, and that icon is what made Ata look like it had not closed.
    static func policyWhenIdle(dock: Bool) -> NSApplication.ActivationPolicy {
        dock ? .regular : .accessory
    }

    /// Applies the Dock setting. `.regular` puts Ata in the Dock and in ⌘-Tab;
    /// `.accessory` is the menu bar app it has always been. Safe to call again
    /// with the same value, and safe before any window exists.
    static func apply() {
        // Nil outside a running app — under the test runner, say — where there is
        // no Dock to put an icon in and nothing to apply.
        guard let app = NSApp else { return }
        let wanted = policyWhenIdle(dock: showsDockIcon)
        guard app.activationPolicy() != wanted else { return }
        app.setActivationPolicy(wanted)
        // Coming back from .accessory, the app is not frontmost until asked:
        // without this the Dock icon appears with nothing in front of it.
        if wanted == .regular { app.activate(ignoringOtherApps: true) }
    }

    /// Turning the Dock icon off would strand an app whose menu bar icon is
    /// also hidden, so the menu bar icon comes back with it.
    static func setDockIcon(_ on: Bool) {
        Pref.d.set(on, forKey: Pref.dockIcon)
        if !on { Pref.d.set(true, forKey: Pref.menuBarIcon) }
        apply()
    }
}
