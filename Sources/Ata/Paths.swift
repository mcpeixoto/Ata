import Foundation

enum Paths {
    #if os(macOS)
    static let home = FileManager.default.homeDirectoryForCurrentUser
    #else
    /// The app's own container on iPhone.
    static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    #endif

    /// Each meeting gets its own folder: ~/Documents/Meetings/<date>/ on the Mac;
    /// on iPhone, Documents/Meetings inside the app, where the Files app shows it.
    /// With "Keep meetings in iCloud" on, Meetings in Ata's iCloud container
    /// instead; see `CloudLibrary`.
    static var meetingsDir: URL { CloudLibrary.location.meetings }

    /// The meetings folder on this device, whether or not iCloud is in use.
    /// `ATA_MEETINGS_DIR` points it elsewhere, for development and for the
    /// README screenshots, which must never show anyone's real meetings.
    static let localMeetingsDir: URL = {
        if let custom = ProcessInfo.processInfo.environment["ATA_MEETINGS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #if os(macOS)
        return home.appendingPathComponent("Documents/Meetings", isDirectory: true)
        #else
        return URL.documentsDirectory.appendingPathComponent("Meetings", isDirectory: true)
        #endif
    }()

    /// Models and voice data. `ATA_SUPPORT_DIR` points it elsewhere, so tests
    /// and development never touch the real library.
    static let supportDir: URL = {
        if let custom = ProcessInfo.processInfo.environment["ATA_SUPPORT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        #if os(macOS)
        return home.appendingPathComponent("Library/Application Support/Ata", isDirectory: true)
        #else
        return URL.applicationSupportDirectory.appendingPathComponent("Ata", isDirectory: true)
        #endif
    }()

    /// Recordings in progress, one folder each. A folder only moves into the
    /// meetings folder once its audio is closed, so nothing reads, or syncs, a
    /// half-written file.
    static let stagingDir = supportDir.appendingPathComponent("Recording", isDirectory: true)
    static let modelsDir = supportDir.appendingPathComponent("models", isDirectory: true)
    /// Voice fingerprints and samples: on this device, or with the meetings in
    /// your iCloud when those are there. Never sent anywhere else.
    static var voicesDir: URL { CloudLibrary.location.voices }
    static let localVoicesDir = supportDir.appendingPathComponent("voices", isDirectory: true)

    /// `ATA_MEETINGS_DIR` or `ATA_SUPPORT_DIR` is set: a development or test run,
    /// which never touches iCloud.
    static let overridden: Bool = ["ATA_MEETINGS_DIR", "ATA_SUPPORT_DIR"].contains {
        !(ProcessInfo.processInfo.environment[$0] ?? "").isEmpty
    }

    /// The selected local model; see `LocalModel` for the catalogue.
    static var whisperModel: URL { LocalModel.current.path }
    static let vadModel = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin")
    static let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    /// whisper-cli ships inside Ata.app (`scripts/build-whisper.sh`). Homebrew's is
    /// only there for `swift test`, which has no app around it. An iPhone app
    /// cannot start another program, so there it is never found.
    static func whisperCLI() -> URL? {
        #if os(macOS)
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return firstExecutable(["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
        #else
        return nil
        #endif
    }

    private static func firstExecutable(_ paths: [String]) -> URL? {
        paths.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Size of the file, following symlinks — so a model linked in from
    /// another disk counts as downloaded.
    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static var hasWhisperModel: Bool { LocalModel.current.isInstalled }
    static var hasVADModel: Bool { fileSize(vadModel) > 100_000 }
}

enum Pref {
    static let language = "language"         // "auto" | "pt" | "en" | …
    static let autoDetect = "autoDetect"     // detect meetings
    static let autoStart = "autoStart"       // record on detection (otherwise ask)
    static let autoStop = "autoStop"         // stop when the meeting ends
    static let keepAudio = "keepAudio"       // keep the audio after transcribing
    static let compressAudio = "compressAudio" // re-encode kept audio to m4a
    static let saveMP3 = "saveMP3"           // also keep both tracks mixed into meeting.mp3
    static let myName = "myName"             // how you appear in the transcript
    static let onboarded = "onboarded"
    static let engine = "engine"             // "local" | "openai"
    static let openAIRetired = "openAIRetired"
    static let loginItemOffered = "loginItemOffered"
    static let appleBannerDismissed = "appleBannerDismissed"
    static let localModel = "localModel"     // LocalModel.id
    static let summarize = "summarize"       // append an AI summary
    static let summaryTemplate = "summaryTemplate" // SummaryTemplate.rawValue
    static let dictionary = "dictionary"       // the user's own names and words, as typed
    static let audioRetentionDays = "audioRetentionDays" // 0 = keep forever
    static let recogniseVoices = "recogniseVoices" // diarize and match voices
    static let cancelEcho = "cancelEcho"     // take the others out of the mic before transcribing
    static let autoUpdate = "autoUpdate"     // check GitHub for new releases
    static let updateFeed = "updateFeed"     // override the release feed (forks)
    static let calendarPrompt = "calendarPrompt"           // offer to record before a calendar meeting starts
    static let calendarLeadMinutes = "calendarLeadMinutes" // how long before it starts
    static let calendarPeopleOnly = "calendarPeopleOnly"   // only events with other people invited
    static let calendarIDs = "calendarIDs"                 // EKCalendar identifiers to watch; absent = all
    static let calendarCategories = "calendarCategories"   // [EKCalendar identifier: MeetingCategory.rawValue]
    static let defaultCategory = "defaultCategory"         // MeetingCategory.rawValue for new meetings; absent = none
    static let categoryFilter = "categoryFilter"           // the lists' filter: "" = all, or MeetingCategory.rawValue
    static let recordShortcut = "recordShortcut" // global key combination that starts or stops recording
    static let dockIcon = "dockIcon"         // show Ata in the Dock and ⌘-Tab, like any other app
    static let menuBarIcon = "menuBarIcon"   // keep the menu bar icon (the only way in, unless the Dock icon is on)
    /// Set once the menu-bar home, Whisper Large and Apple Intelligence
    /// defaults have been written. A later change in Settings is not overwritten.
    static let menuBarHome = "menuBarHome"
    static let menuIconSymbol = "menuIconSymbol"     // MenuIcon.Symbol while recording
    static let menuIconTint = "menuIconTint"         // MenuIcon.Tint while recording
    static let menuIconTimer = "menuIconTimer"       // elapsed time next to the icon
    static let menuIconPulse = "menuIconPulse"       // icon breathes while recording
    static let menuIconProgress = "menuIconProgress" // % next to the icon while transcribing
    static let recordingMode = "recordingMode"   // iPhone: RecordingMode.rawValue
    static let iCloudSync = "iCloudSync"         // meetings and voices are in iCloud; set once the copy is checked
    static let iCloudMigrating = "iCloudMigrating" // copying into iCloud, to resume after a quit
    static let iCloudDocuments = "iCloudDocuments" // the container's Documents folder, as last found
    static let fixedSystemWriterSince = "fixedSystemWriterSince" // first launch of a build whose system-audio writer is fixed

    /// The languages Ata offers for transcription, by their own names: Settings on
    /// both platforms, and "Transcribe again in" on the iPhone. Endonyms, so they
    /// read the same whatever the app's language; "Automatic" is translated.
    static let languageChoices: [(code: String, name: String)] = [
        ("en", "English"), ("pt", "Português"), ("es", "Español"),
        ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"),
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: platformDefaults.merging([
            language: "auto",
            autoDetect: true,
            autoStart: false,
            autoStop: true,
            keepAudio: true,
            compressAudio: true,
            saveMP3: true,
            myName: defaultName,
            onboarded: false,
            engine: Engine.local.rawValue,
            summarize: true,
            autoUpdate: true,
            audioRetentionDays: 0,
            // On. Knowing who said what is the point of a transcript of a
            // conversation, and a transcript where everyone is "Me" or "Them" is
            // the complaint this default used to cause. Fingerprints never leave
            // the device (or the user's own iCloud); the one cost is 21 MB of
            // models, downloaded the first time a meeting is transcribed.
            recogniseVoices: true,
            cancelEcho: true,
            iCloudSync: false,
        ]) { platform, _ in platform })
    }

    /// Your first name, for transcripts, until you type the one you want.
    private static var defaultName: String {
        #if os(macOS)
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? L("Me") : first
        #else
        // An iPhone app can't read its owner's name: "Me" until you type yours.
        return L("Me")
        #endif
    }

    /// Defaults for settings that only one platform has.
    static var platformDefaults: [String: Any] {
        #if os(macOS)
        return [
            // Ata has always been a menu bar app, and stays one unless you say
            // otherwise. The Dock icon is there for a menu bar too full to find
            // it in — macOS gives an app no say in where its icon sits, and hides
            // the ones that don't fit.
            // Off until the user has both granted calendar access and asked for
            // this: Ata never requests a permission it was not asked to use.
            calendarPrompt: false,
            // What was asked for. Long enough to answer, short enough that it is
            // still about this meeting.
            calendarLeadMinutes: 1,
            // A block on your own calendar with nobody else on it is not a
            // meeting. This is also what keeps holidays and birthdays out
            // without making the user curate a list of calendars.
            calendarPeopleOnly: true,
            dockIcon: false,
            menuBarIcon: true,
            menuIconSymbol: MenuIcon.Symbol.dot.rawValue,
            // Recording someone should be impossible to miss.
            menuIconTint: MenuIcon.Tint.red.rawValue,
            recordShortcut: Shortcut.defaultRecord.stored,
            menuIconTimer: true,
            menuIconPulse: false,
            menuIconProgress: true,
        ]
        #else
        // The phone transcribes and summarizes with Apple's on-device models, which
        // cost nothing.
        return [
            engine: Engine.apple.rawValue,
            summarize: true,
        ]
        #endif
    }

    /// Once, on the Mac: Ata lives in the menu bar, transcribes with Whisper
    /// Large and writes summaries. Does nothing the
    /// second time, so turning the Dock icon back on in Settings sticks.
    static func applyMenuBarHome(to defaults: UserDefaults = .standard) {
        #if os(macOS)
        guard !defaults.bool(forKey: menuBarHome) else { return }
        defaults.set(false, forKey: dockIcon)
        defaults.set(true, forKey: menuBarIcon)
        defaults.set(Engine.local.rawValue, forKey: engine)
        defaults.set(LocalModel.defaultID, forKey: localModel)
        defaults.set(true, forKey: summarize)
        defaults.set(true, forKey: menuBarHome)
        #endif
    }

    /// Once, on the Mac: clears what older versions kept for OpenAI, and the model
    /// choice that no longer exists. Returns whether it ran, because the API key
    /// is deleted by the caller, away from launch: a keychain call can block.
    /// Never touches the Dock choice.
    @discardableResult
    static func retireOpenAI(to defaults: UserDefaults = .standard) -> Bool {
        #if os(macOS)
        guard !defaults.bool(forKey: openAIRetired) else { return false }
        for key in ["openAIModel", "summaryModel", "summaryEngine", localModel] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(Engine.local.rawValue, forKey: engine)
        defaults.set(true, forKey: openAIRetired)
        return true
        #else
        return false
        #endif
    }

    static var d: UserDefaults { .standard }

    /// Your name in transcripts. An empty field means "Me", never a blank speaker.
    static var myNameOrDefault: String {
        let name = d.string(forKey: myName)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? L("Me") : name
    }
}
