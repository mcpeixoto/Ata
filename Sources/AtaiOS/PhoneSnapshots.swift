import SwiftUI

/// Screenshots of the iPhone app, for reviewing the UI without a device.
///
/// The AtaUITests target (ios/UITests, run by ios/snapshots.sh and CI) launches
/// Ata in a simulator once per screen with `-AtaSnapshots <screen>` and
/// `-AtaSnapshotAppearance light|dark`, and points `ATA_MEETINGS_DIR` and
/// `ATA_SUPPORT_DIR` at made-up meetings from scripts/lib/make-fixtures.py.
/// Such a launch skips `PhoneStore.bootstrap()`: nothing is recorded,
/// transcribed, recovered, synced or announced, and the microphone is never
/// asked for. Without the argument none of this runs.
extension Snapshots {
    /// What the UI test photographs. The raw value is the launch argument and
    /// the PNG's name; ios/UITests/AtaSnapshotTests.swift has the same list.
    enum Screen: String {
        case recordIdle = "record-idle"
        case recordRecording = "record-recording"
        case meetings
        case meetingNotes = "meeting-notes"
        case meetingTranscript = "meeting-transcript"
        case people
        case insights
        case settings
        case onboarding
    }

    static let screen: Screen = Snapshots.argument(after: "-AtaSnapshots").flatMap(Screen.init(rawValue:)) ?? .recordIdle

    /// Light or dark for the whole window, sheets and bars included. Nil, so no
    /// preference at all, in a normal launch.
    static let colorScheme: ColorScheme? = {
        guard Snapshots.rendering else { return nil }
        return Snapshots.argument(after: "-AtaSnapshotAppearance") == "dark" ? .dark : .light
    }()

    /// The README's meeting: a summary, your notes, a transcript and two voices.
    static let meetingID = "fixture-zoom"
    /// Shown mid-transcription in the meetings list, as on the Mac's screenshots.
    static let transcribingID = "fixture-slack"

    private static func argument(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// In place of the normal launch: the fixtures, and the screen asked for.
    @MainActor
    static func setUp() {
        guard rendering else { return }
        Pref.registerDefaults()
        // A development folder, so iCloud shows as available and is never used.
        CloudSync.shared.start(isIdle: { false }, changed: {})

        // Mid-meeting: 23 minutes in, a voice in the room, two moments marked.
        let recording = screen == .recordRecording
        PhoneStore.shared.applySnapshotFixture(recording: recording,
                                               elapsed: recording ? 23 * 60 + 14 : 0,
                                               level: recording ? 0.64 : 0,
                                               bookmarks: recording ? [4 * 60_000 + 12_000, 17 * 60_000 + 40_000] : [],
                                               transcribingID: recording ? nil : transcribingID,
                                               progress: recording ? 0 : 0.62)

        let navigation = PhoneNavigation.shared
        navigation.showingOnboarding = screen == .onboarding
        switch screen {
        case .recordIdle, .recordRecording, .onboarding:
            navigation.tab = .record
        case .meetings:
            navigation.tab = .meetings
        case .meetingNotes, .meetingTranscript:
            // The UI test taps "Transcript" itself, the way you would.
            navigation.showMeeting(meetingID)
        case .people:
            navigation.tab = .people
        case .insights:
            navigation.tab = .insights
        case .settings:
            navigation.tab = .settings
        }
    }

    /// Called by every new `MeetingModel`: the fixture meeting opens mid-playback,
    /// so the transcript shows the word being heard. The audio is never loaded.
    @MainActor
    static func position(_ player: MeetingPlayer, meeting id: String) {
        guard rendering, id == meetingID else { return }
        player.applySnapshotPosition(10.4, duration: 58)
    }
}
