import Foundation

/// The Whisper models Ata can run locally with whisper.cpp.
///
/// The list, the default and the descriptions come from measured word error
/// rates on real European Portuguese and English speech, clean and
/// telephone-degraded — see docs/plans for the numbers.
struct LocalModel: Identifiable, Equatable {
    let id: String
    let file: String
    /// Exact size of the published file, used both for the UI and to tell a
    /// finished download from a truncated one.
    let bytes: Int64
    let title: String
    let detail: String

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }
    var path: URL { Paths.modelsDir.appendingPathComponent(file) }

    /// A download within 2% of the published size counts as complete; Hugging
    /// Face occasionally re-uploads a file with a slightly different size.
    var isInstalled: Bool { Paths.fileSize(path) >= Int64(Double(bytes) * 0.98) }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static let all: [LocalModel] = [
        LocalModel(id: "large-v3", file: "ggml-large-v3.bin", bytes: 3_095_033_483,
                   title: L("Large v3"), detail: L("Most accurate. Slower, biggest download.")),
        LocalModel(id: "large-v3-q5_0", file: "ggml-large-v3-q5_0.bin", bytes: 1_081_140_203,
                   title: L("Large v3 (compressed)"), detail: L("Nearly as accurate, a third of the size.")),
        LocalModel(id: "large-v3-turbo", file: "ggml-large-v3-turbo.bin", bytes: 1_624_555_275,
                   title: L("Large v3 Turbo"), detail: L("Fastest. Weaker on accents and noisy calls.")),
        LocalModel(id: "large-v3-turbo-q5_0", file: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195,
                   title: L("Large v3 Turbo (compressed)"), detail: L("Smallest download, lowest accuracy.")),
    ]

    static let defaultID = "large-v3-q5_0"

    static func find(_ id: String) -> LocalModel? { all.first { $0.id == id } }

    /// The model the user picked, or the default.
    static var current: LocalModel {
        find(Pref.d.string(forKey: Pref.localModel) ?? defaultID) ?? find(defaultID)!
    }

    static var installed: [LocalModel] { all.filter(\.isInstalled) }
}
