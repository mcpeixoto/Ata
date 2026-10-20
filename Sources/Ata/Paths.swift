import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Each meeting gets its own folder: ~/Documents/Meetings/<date>/
    /// `ATA_MEETINGS_DIR` points it elsewhere, for development and for the
    /// README screenshots, which must never show anyone's real meetings.
    static let meetingsDir: URL = {
        if let custom = ProcessInfo.processInfo.environment["ATA_MEETINGS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home.appendingPathComponent("Documents/Meetings", isDirectory: true)
    }()

    static let supportDir = home.appendingPathComponent("Library/Application Support/Ata", isDirectory: true)
    static let modelsDir = supportDir.appendingPathComponent("models", isDirectory: true)
    /// Voice fingerprints and samples. Never uploaded.
    static let voicesDir = supportDir.appendingPathComponent("voices", isDirectory: true)

    /// The selected local model; see `LocalModel` for the catalogue.
    static var whisperModel: URL { LocalModel.current.path }
    static let vadModel = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin")
    static let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    static func whisperCLI() -> URL? {
        firstExecutable(["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"])
    }

    static func brew() -> URL? {
        firstExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
    }

    private static func firstExecutable(_ paths: [String]) -> URL? {
        paths.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
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
    static let myName = "myName"             // how you appear in the transcript
    static let onboarded = "onboarded"
    static let engine = "engine"             // "local" | "openai"
    static let localModel = "localModel"     // LocalModel.id
    static let openAIModel = "openAIModel"
    static let summarize = "summarize"       // append an AI summary
    static let summaryModel = "summaryModel"
    static let audioRetentionDays = "audioRetentionDays" // 0 = keep forever
    static let autoUpdate = "autoUpdate"     // check GitHub for new releases
    static let updateFeed = "updateFeed"     // override the release feed (forks)

    static let defaultOpenAIModel = "whisper-1"
    static let defaultSummaryModel = "gpt-4o-mini"

    /// OpenAI transcription models offered in Settings.
    /// Only `whisper-1` returns per-segment timestamps; the others are more
    /// accurate but give a transcript without per-line times.
    static let openAIModels = ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    static let summaryModels = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1"]

    static func registerDefaults() {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? L("Me")
        UserDefaults.standard.register(defaults: [
            language: "auto",
            autoDetect: true,
            autoStart: false,
            autoStop: true,
            keepAudio: true,
            compressAudio: true,
            myName: first.isEmpty ? L("Me") : first,
            onboarded: false,
            engine: Engine.local.rawValue,
            localModel: LocalModel.defaultID,
            openAIModel: defaultOpenAIModel,
            summarize: false,
            summaryModel: defaultSummaryModel,
            autoUpdate: true,
            audioRetentionDays: 0,
        ])
    }

    static var d: UserDefaults { .standard }
}
