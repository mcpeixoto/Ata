import AppIntents

/// Ata's actions for Siri, Spotlight, Shortcuts and the Action button, with no
/// setup: they're there as soon as the app is installed.
struct AtaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Record with \(.applicationName)",
                              "Start recording with \(.applicationName)"],
                    shortTitle: "Record",
                    systemImageName: "mic.fill")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Stop recording with \(.applicationName)"],
                    shortTitle: "Stop recording",
                    systemImageName: "stop.fill")
        AppShortcut(intent: BookmarkIntent(),
                    phrases: ["Bookmark this moment in \(.applicationName)"],
                    shortTitle: "Bookmark",
                    systemImageName: "bookmark.fill")
    }
}
