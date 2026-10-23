import UIKit
import UniformTypeIdentifiers

@MainActor
enum Platform {
    static let actions: PlatformActions = PhoneActions()
}

/// The iPhone side of `PlatformActions`: the pasteboard, the system's export
/// sheet, and the Files app.
@MainActor
final class PhoneActions: NSObject, PlatformActions, UIDocumentPickerDelegate {
    private var pending: CheckedContinuation<Bool, Never>?

    func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// The file is written first, into a temporary folder, and then handed to the
    /// system sheet that asks where it goes; the sheet copies it there.
    func saveFile(named name: String, type: UTType,
                  write: @escaping @MainActor (URL) async throws -> Void) async throws -> Bool {
        let dir = MeetingSharing.root.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(name)
        try await write(file)

        guard pending == nil, let presenter = Self.topViewController() else { return false }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = self
        return await withCheckedContinuation { continuation in
            pending = continuation
            presenter.present(picker, animated: true)
        }
    }

    /// Opens the folder in the Files app, where Ata's Documents folder shows as
    /// "On My iPhone › Ata".
    func reveal(_ url: URL) {
        open(url)
    }

    func open(_ url: URL) {
        guard let files = Self.filesURL(for: url) else { return }
        UIApplication.shared.open(files)
    }

    /// The Files app's own scheme for a local path.
    static func filesURL(for url: URL) -> URL? {
        URL(string: "shareddocuments://" + url.path(percentEncoded: true))
    }

    // MARK: UIDocumentPickerDelegate

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        MainActor.assumeIsolated { finish(true) }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        MainActor.assumeIsolated { finish(false) }
    }

    private func finish(_ saved: Bool) {
        pending?.resume(returning: saved)
        pending = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
