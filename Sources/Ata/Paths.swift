import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Cada meeting fica numa pasta própria: ~/Documents/Meetings/<data>/
    static let meetingsDir = home.appendingPathComponent("Documents/Meetings", isDirectory: true)

    static let supportDir = home.appendingPathComponent("Library/Application Support/Ata", isDirectory: true)
    static let modelsDir = supportDir.appendingPathComponent("models", isDirectory: true)

    static let whisperModel = modelsDir.appendingPathComponent("ggml-large-v3-turbo.bin")
    static let vadModel = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin")

    static let whisperModelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    static let vadModelURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    /// O modelo turbo tem ~1.6 GB; abaixo disto o ficheiro está incompleto.
    static let whisperModelMinBytes: Int64 = 1_400_000_000

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

    static var hasWhisperModel: Bool { fileSize(whisperModel) >= whisperModelMinBytes }
    static var hasVADModel: Bool { fileSize(vadModel) > 100_000 }
}

enum Pref {
    static let language = "language"       // "auto" | "pt" | "en"
    static let autoDetect = "autoDetect"   // detetar meetings
    static let autoStart = "autoStart"     // gravar sozinho quando deteta (senão pergunta)
    static let autoStop = "autoStop"       // parar quando a meeting acaba
    static let keepAudio = "keepAudio"     // guardar o áudio depois de transcrever
    static let myName = "myName"           // como apareces na transcrição
    static let onboarded = "onboarded"

    static func registerDefaults() {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Eu"
        UserDefaults.standard.register(defaults: [
            language: "auto",
            autoDetect: true,
            autoStart: false,
            autoStop: true,
            keepAudio: false,
            myName: first.isEmpty ? "Eu" : first,
            onboarded: false,
        ])
    }

    static var d: UserDefaults { .standard }
}
