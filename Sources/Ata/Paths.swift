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

    /// whisper-cli and Homebrew are Mac programs. An iPhone app cannot start
    /// another program, so there they are never found.
    static func whisperCLI() -> URL? {
        #if os(macOS)
        return firstExecutable(["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
        #else
        return nil
        #endif
    }

    static func brew() -> URL? {
        #if os(macOS)
        return firstExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
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
    static let localModel = "localModel"     // LocalModel.id
    static let openAIModel = "openAIModel"
    static let summarize = "summarize"       // append an AI summary
    static let summaryModel = "summaryModel"
    static let summaryEngine = "summaryEngine" // "auto" | SummaryEngine.rawValue
    static let audioRetentionDays = "audioRetentionDays" // 0 = keep forever
    static let recogniseVoices = "recogniseVoices" // diarize and match voices; off by default
    static let cancelEcho = "cancelEcho"     // take the others out of the mic before transcribing
    static let autoUpdate = "autoUpdate"     // check GitHub for new releases
    static let updateFeed = "updateFeed"     // override the release feed (forks)
    static let menuIconSymbol = "menuIconSymbol"     // MenuIcon.Symbol while recording
    static let menuIconTint = "menuIconTint"         // MenuIcon.Tint while recording
    static let menuIconTimer = "menuIconTimer"       // elapsed time next to the icon
    static let menuIconPulse = "menuIconPulse"       // icon breathes while recording
    static let menuIconProgress = "menuIconProgress" // % next to the icon while transcribing
    static let recordingMode = "recordingMode"   // iPhone: RecordingMode.rawValue
    static let iCloudSync = "iCloudSync"         // meetings and voices are in iCloud; set once the copy is checked
    static let iCloudMigrating = "iCloudMigrating" // copying into iCloud, to resume after a quit
    static let iCloudDocuments = "iCloudDocuments" // the container's Documents folder, as last found

    /// The languages Ata offers for transcription, by their own names: Settings on
    /// both platforms, and "Transcribe again in" on the iPhone. Endonyms, so they
    /// read the same whatever the app's language; "Automatic" is translated.
    static let languageChoices: [(code: String, name: String)] = [
        ("en", "English"), ("pt", "Português"), ("es", "Español"),
        ("fr", "Français"), ("de", "Deutsch"), ("it", "Italiano"),
    ]

    static let defaultOpenAIModel = "whisper-1"
    static let defaultSummaryModel = "gpt-4o-mini"

    /// OpenAI transcription models offered in Settings.
    /// Only `whisper-1` returns per-segment timestamps; the others are more
    /// accurate but give a transcript without per-line times.
    static let openAIModels = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    static let summaryModels = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]

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
            openAIModel: defaultOpenAIModel,
            summarize: false,
            summaryModel: defaultSummaryModel,
            summaryEngine: "auto",
            autoUpdate: true,
            audioRetentionDays: 0,
            recogniseVoices: false,
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
    private static var platformDefaults: [String: Any] {
        #if os(macOS)
        return [
            menuIconSymbol: MenuIcon.Symbol.dot.rawValue,
            menuIconTint: MenuIcon.Tint.monochrome.rawValue,
            menuIconTimer: true,
            menuIconPulse: false,
            menuIconProgress: true,
        ]
        #else
        // The phone transcribes and summarizes with Apple's on-device models, which
        // cost nothing, and an in-person recording needs voices told apart.
        return [
            engine: Engine.apple.rawValue,
            summarize: true,
            recogniseVoices: true,
        ]
        #endif
    }

    static var d: UserDefaults { .standard }

    /// Your name in transcripts. An empty field means "Me", never a blank speaker.
    static var myNameOrDefault: String {
        let name = d.string(forKey: myName)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? L("Me") : name
    }
}
