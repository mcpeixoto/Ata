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
        case recordFirstRun = "record-first-run"
        case recordTranscribing = "record-transcribing"
        case meetings
        case meetingNotes = "meeting-notes"
        case meetingTranscript = "meeting-transcript"
        case people
        case insights
        case settings
        case iCloudHelp = "icloud-help"
        case onboarding
        case onboardingUseCase = "onboarding-usecase"
        case onboardingPermissions = "onboarding-permissions"
        case onboardingYou = "onboarding-you"
        case onboardingTry = "onboarding-try"
        case onboardingPro = "onboarding-pro"
        case paywall
        case paywallLimit = "paywall-limit"
        case paywallMonthly = "paywall-monthly"
        case meetingsEmptyXXL = "meetings-empty-xxl"
        case insightsEmptyXXL = "insights-empty-xxl"
        case peopleOffXXL = "people-off-xxl"
    }

    static let screen: Screen = Snapshots.argument(after: "-AtaSnapshots").flatMap(Screen.init(rawValue:)) ?? .recordIdle

    /// Light or dark for the whole window, sheets and bars included. Nil, so no
    /// preference at all, in a normal launch.
    static let colorScheme: ColorScheme? = {
        guard Snapshots.rendering else { return nil }
        return Snapshots.argument(after: "-AtaSnapshotAppearance") == "dark" ? .dark : .light
    }()

    /// The storekit file's prices, formatted the way `Product.displayPrice`
    /// would for this launch's locale. StoreKit's test configuration only
    /// reaches runs started from Xcode, not a UI test's launch, so the paywall
    /// reads these instead of a hard-coded currency.
    static let monthlyDecimal: Decimal = Decimal(string: "6.99")!
    static let yearlyDecimal: Decimal = Decimal(string: "44.99")!

    static func format(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: currencyCode).locale(priceLocale).presentation(.narrow))
    }

    /// en_US shows dollars. A Portuguese locale shows euros, the same amounts.
    private static var priceLocale: Locale {
        localeIsPortuguese ? Locale(identifier: "pt_PT") : Locale(identifier: "en_US")
    }

    private static var currencyCode: String { localeIsPortuguese ? "EUR" : "USD" }

    private static var localeIsPortuguese: Bool {
        let id = Locale.current.identifier.lowercased().replacingOccurrences(of: "-", with: "_")
        return id.hasPrefix("pt")
    }

    /// The README's meeting: a summary, your notes, a transcript and two voices.
    static let meetingID = "fixture-zoom"
    /// Shown mid-transcription in the meetings list, as on the Mac's screenshots.
    static let transcribingID = "fixture-slack"

    /// 212 of 300 on the Record home and the paywall mock (the meter, no banner),
    /// past 80 % while transcribing (the banner), none on a first run, and the
    /// month used up on the limit paywall. Everywhere else, two minutes are left.
    private static var freeUsed: Int {
        switch screen {
        case .paywall, .paywallMonthly, .recordIdle: return 212
        case .paywallLimit: return FreeQuota.limitMinutes
        case .recordTranscribing: return 250
        case .recordFirstRun: return 0
        default: return FreeQuota.limitMinutes - 2
        }
    }

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
        // The Record home shows the transcribing card only on its own screen.
        let quietHome = screen == .recordIdle || screen == .recordFirstRun
        let emptyLibrary = screen == .meetingsEmptyXXL || screen == .insightsEmptyXXL
        PhoneStore.shared.applySnapshotFixture(recording: recording,
                                               elapsed: recording ? 23 * 60 + 14 : 0,
                                               level: recording ? 0.64 : 0,
                                               bookmarks: recording ? [4 * 60_000 + 12_000, 17 * 60_000 + 40_000] : [],
                                               transcribingID: recording || quietHome || emptyLibrary ? nil : transcribingID,
                                               progress: recording || quietHome || emptyLibrary ? 0 : 0.62,
                                               freeUsed: freeUsed,
                                               emptyLibrary: emptyLibrary)

        let navigation = PhoneNavigation.shared
        switch screen {
        case .onboarding:
            navigation.showOnboarding(at: .welcome)
        case .onboardingUseCase:
            navigation.showOnboarding(at: .useCase)
        case .onboardingPermissions:
            navigation.showOnboarding(at: .permissions)
        case .onboardingYou:
            navigation.showOnboarding(at: .you)
        case .onboardingTry:
            navigation.showOnboarding(at: .tryIt)
        case .onboardingPro:
            navigation.showOnboarding(at: .pro)
        default:
            break
        }
        switch screen {
        case .paywallLimit:
            ProPromptCenter.shared.trigger = .limit
            ProPromptCenter.shared.preferYearly = true
        case .paywallMonthly:
            ProPromptCenter.shared.trigger = .settings
            ProPromptCenter.shared.preferYearly = false
        case .paywall:
            ProPromptCenter.shared.trigger = .settings
            ProPromptCenter.shared.preferYearly = true
        default:
            break
        }
        navigation.showingPaywall = screen == .paywall || screen == .paywallLimit || screen == .paywallMonthly
        switch screen {
        case .recordIdle, .recordRecording, .recordFirstRun, .recordTranscribing, .onboarding, .onboardingUseCase,
                .onboardingPermissions, .onboardingYou, .onboardingTry, .onboardingPro,
                .paywall, .paywallLimit, .paywallMonthly:
            navigation.tab = .record
        case .meetings, .meetingsEmptyXXL:
            navigation.tab = .meetings
        case .meetingNotes, .meetingTranscript:
            // The UI test taps "Transcript" itself, the way you would.
            navigation.showMeeting(meetingID)
        case .people, .peopleOffXXL:
            navigation.tab = .people
        case .insights, .insightsEmptyXXL:
            navigation.tab = .insights
        case .settings, .iCloudHelp:
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
