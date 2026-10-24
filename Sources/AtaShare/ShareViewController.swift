import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Ata" in the share sheet. An extension can't run the transcription queue,
/// so it copies the shared audio into the app group's inbox and says so; Ata
/// makes the meetings the next time it opens (see `ShareInbox`).
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.onDone = { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        let host = UIHostingController(rootView: ShareConfirmation(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        model.add(items.flatMap { $0.attachments ?? [] })
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State: Equatable {
        case copying
        case added(Int)
        case failed(String)
    }

    @Published private(set) var state: State = .copying
    var onDone: () -> Void = {}

    private var remaining = 0
    private var added = 0
    private var lastError: String?

    /// Copies every audio attachment, up to `ShareInbox.maxFiles`, into the inbox.
    func add(_ providers: [NSItemProvider]) {
        guard let folder = ShareInbox.folder else {
            state = .failed(L("Ata could not reach its shared folder. Open Ata and import the file from there."))
            return
        }
        let audio = providers.compactMap { provider -> (NSItemProvider, UTType)? in
            guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .audio) }) else { return nil }
            return (provider, type)
        }.prefix(ShareInbox.maxFiles)
        guard !audio.isEmpty else {
            state = .failed(L("Ata can only import audio files."))
            return
        }
        remaining = audio.count
        let now = Date()
        for (provider, type) in audio {
            let suggested = provider.suggestedName
            // The file only exists until this handler returns, so it is copied here.
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, loadError in
                var message: String?
                if let url {
                    do {
                        let name = ShareInbox.originalName(suggested: suggested, file: url)
                        let date = Self.recordedDate(of: url) ?? now
                        try ShareInbox.add(url, originalName: name, date: date, to: folder)
                    } catch {
                        message = error.localizedDescription
                    }
                } else {
                    message = loadError?.localizedDescription ?? L("Ata can only import audio files.")
                }
                let failure = message
                Task { @MainActor in self.finishedOne(error: failure) }
            }
        }
    }

    private func finishedOne(error: String?) {
        if let error { lastError = error } else { added += 1 }
        remaining -= 1
        guard remaining == 0 else { return }
        state = added > 0 ? .added(added) : .failed(lastError ?? L("Ata can only import audio files."))
    }

    /// As on the Mac, the earliest date the file has: a handed-over file often
    /// keeps the recording's, a fresh temporary copy has about now.
    nonisolated private static func recordedDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.min()
    }
}

struct ShareConfirmation: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                switch model.state {
                case .copying:
                    ProgressView()
                        .controlSize(.large)
                    Text("Adding to Ata…")
                        .font(.headline)
                case .added(let count):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Added to Ata")
                        .font(.title2.bold())
                    Text(count == 1
                         ? L("It will be transcribed when you open Ata.")
                         : L("They will be transcribed when you open Ata."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Could not add this to Ata")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { model.onDone() }
                        .disabled(model.state == .copying)
                }
            }
        }
    }
}
