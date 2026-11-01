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

    /// Word error rates below are from 425 runs on real European Portuguese and
    /// English speech; times are per hour of audio on an M4.
    static let all: [LocalModel] = [
        LocalModel(id: "large-v3-q5_0", file: "ggml-large-v3-q5_0.bin", bytes: 1_081_140_203,
                   title: L("Large v3"),
                   detail: L("Most accurate, best for Portuguese and noisy calls. About 11 minutes per hour of audio.")),
        LocalModel(id: "large-v3-turbo", file: "ggml-large-v3-turbo.bin", bytes: 1_624_555_275,
                   title: L("Turbo"),
                   detail: L("Fastest, a little less accurate. About 3 minutes per hour of audio.")),
        LocalModel(id: "large-v3-turbo-q5_0", file: "ggml-large-v3-turbo-q5_0.bin", bytes: 574_041_195,
                   title: L("Turbo compact"),
                   detail: L("Turbo's accuracy in a third of the download and under 1 GB of memory. About 4 minutes per hour.")),
    ]

    static let defaultID = "large-v3-q5_0"

    static func find(_ id: String) -> LocalModel? { all.first { $0.id == id } }

    /// The model Ata transcribes with. There is one on purpose: the catalogue only
    /// remains so that a model left on disk by an older version can be found and
    /// removed, and for tests that want a smaller one.
    static var current: LocalModel { find(defaultID)! }

    static var installed: [LocalModel] { all.filter(\.isInstalled) }
}
