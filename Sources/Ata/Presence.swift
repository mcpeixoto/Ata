import AppKit

/// ⌘Q closes Ata's windows. The menu bar icon is the app, so the usual "quit"
/// keystroke must not take it away; Quit Ata in the menu does that.
enum QuitKey {
    static func closesWindows(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        isCommand(characters, "q", modifiers)
    }

    static func closesOneWindow(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        isCommand(characters, "w", modifiers)
    }

    private static func isCommand(_ characters: String?, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        characters?.lowercased() == key
            && modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
    }
}

/// What Quit Ata should warn about. Quitting always keeps the audio; what it
/// costs is time, and that is worth one question.
enum QuitWarning: Equatable {
    case recording, transcribing

    static func needed(recording: Bool, transcribing: Bool) -> QuitWarning? {
        if recording { return .recording }
        return transcribing ? .transcribing : nil
    }

    var title: String {
        switch self {
        case .recording: return L("Ata is recording. Quit anyway?")
        case .transcribing: return L("Ata is transcribing a meeting. Quit anyway?")
        }
    }

    var detail: String {
        switch self {
        case .recording: return L("The recording stops here. It is saved and transcribed the next time Ata opens.")
        case .transcribing: return L("The transcription starts again from the beginning the next time Ata opens.")
        }
    }
}

/// Whether a launch should show a window. Opening Ata by hand and getting
/// nothing looks broken, but a window at every login, update or restart is noise.
enum LaunchWindow {
    /// Passed by Ata when it restarts itself, so that restart stays silent.
    static let quietArgument = "--quiet-launch"

    /// `loginItemEvent`: macOS said it launched Ata as a login item. It doesn't
    /// always say so for `SMAppService`, so a launch moments after startup with
    /// the login item on counts too.
    static func shows(arguments: [String], loginItemEvent: Bool, loginItemOn: Bool, uptime: TimeInterval) -> Bool {
        if arguments.contains(quietArgument) || loginItemEvent { return false }
        return !(loginItemOn && uptime < 180)
    }
}

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
        let window = NSApp?.keyWindow
        Pref.d.set(on, forKey: Pref.dockIcon)
        if !on { Pref.d.set(true, forKey: Pref.menuBarIcon) }
        apply()
        // Changing policy can drop the app's focus, and Settings with it, behind
        // whatever was underneath.
        DispatchQueue.main.async {
            NSApp?.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }
}
