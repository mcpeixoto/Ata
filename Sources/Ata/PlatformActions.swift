import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// The few things a meeting hands to the system around it, which AppKit and
/// UIKit do differently: the clipboard, saving a file where you choose, and
/// showing or opening a file. The Mac's implementation is below; the iPhone's
/// is in Sources/AtaiOS.
@MainActor
protocol PlatformActions {
    func copy(_ text: String)

    /// Saves a file named `name` wherever you choose. `write` produces it at the
    /// URL it is given. False when you cancelled before anything was written.
    func saveFile(named name: String, type: UTType,
                  write: @escaping @MainActor (URL) async throws -> Void) async throws -> Bool

    /// Shows the file or folder where it lives: Finder on the Mac, Files on iPhone.
    func reveal(_ url: URL)

    /// Opens the file in the app that handles it.
    func open(_ url: URL)
}

#if os(macOS)
@MainActor
enum Platform {
    static let actions: PlatformActions = MacActions()
}

@MainActor
struct MacActions: PlatformActions {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The save panel comes first, so nothing is written until you have picked a place.
    func saveFile(named name: String, type: UTType,
                  write: @escaping @MainActor (URL) async throws -> Void) async throws -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        try await write(destination)
        reveal(destination)
        return true
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
#endif
