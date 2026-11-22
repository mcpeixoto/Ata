#if os(macOS)
import SwiftUI

/// Whisper Large: its download, and clean-up of what older versions left on disk.
struct LocalModelRows: View {
    @EnvironmentObject var setup: SetupModel
    /// Bumped after a change so the model state is read again.
    @State private var generation = 0
    @State private var confirmRemove = false

    private var model: LocalModel { _ = generation; return LocalModel.current }
    private var others: [LocalModel] { _ = generation; return LocalModel.installed.filter { $0.id != model.id } }
    private var othersSize: String {
        ByteCountFormatter.string(fromByteCount: others.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }

    var body: some View {
        LabeledContent {
            if setup.model {
                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let p = setup.downloadProgress {
                HStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 90)
                    Text("\(Int(p * 100))%").ataFont(10).monospacedDigit()
                }
            } else {
                Button(L("Download %@", model.sizeText)) { setup.downloadModels() }
            }
        } label: {
            Text("Whisper Large")
        }
        if !others.isEmpty {
            LabeledContent {
                Button("Remove") { confirmRemove = true }
                    .confirmationDialog(L("Remove older models (%@)?", othersSize), isPresented: $confirmRemove) {
                        Button("Remove", role: .destructive) {
                            for m in others { try? FileManager.default.removeItem(at: m.path) }
                            generation += 1
                            setup.refresh()
                        }
                    } message: {
                        Text("Ata no longer uses them. Your recordings and transcripts are not touched.")
                    }
            } label: {
                Text(L("Other models on disk: %@", othersSize))
                    .ataCaption()
                    .foregroundStyle(.secondary)
            }
            .id(generation)
        }
        if let error = setup.downloadError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).ataCaption()
            }
            .foregroundStyle(Theme.danger)
        }
    }
}

/// The recording icon on a strip of menu bar, so a change in Settings shows
/// before the next meeting does.
struct MenuIconPreview: View {
    let style: MenuIcon.Style
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !style.pulse)) { context in
            HStack(spacing: 4) {
                RecordingMenuIcon(style: style, date: context.date)
                if style.timer { Text(verbatim: "12:34").monospacedDigit() }
            }
            // The menu bar status item is 13 pt. The preview matches it, so this
            // strip is what the icon will look like. Black and white are the
            // menu bar's own text, not an app colour.
            .ataFont(13)
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Color.primary.opacity(0.08)))
        }
        .accessibilityHidden(true)
    }
}

/// "Check for updates" / "Install" in one spot, driven by `Updater.state`.
struct UpdateControl: View {
    @StateObject private var updater = Updater.shared

    var body: some View {
        switch updater.state {
        case .idle:
            Button("Check now") { updater.check() }
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").ataCaption() }
        case .upToDate:
            // The button stays. Replacing it with the answer meant that once Ata
            // had told you it was the latest, it went on saying so for the rest of
            // the session — there was nothing left to click, and the only way to
            // ask again was to quit the app.
            HStack(spacing: 8) {
                Label(L("Ata %@ is the latest", Updater.currentVersion), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).ataCaption()
                Button("Check again") { updater.check() }.controlSize(.small)
            }
        case .available(let version, _):
            Button(L("Install %@", version)) { updater.installUpdate() }
                .buttonStyle(.borderedProminent)
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 80)
                Text("\(Int(p * 100))%").ataFont(10).monospacedDigit()
            }
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").ataCaption() }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .ataFont(10).foregroundStyle(Theme.danger)
                Button("Try again") { updater.check() }.controlSize(.small)
            }
        }
    }
}

/// Buy-me-a-coffee link. The destination is in the Info.plist so a fork can
/// point it somewhere else without touching the code.
struct CoffeeButton: View {
    static var donateURL: URL {
        let configured = Bundle.main.object(forInfoDictionaryKey: "AtaDonateURL") as? String
        return URL(string: configured ?? "") ?? URL(string: "https://buymeacoffee.com/mcpeixoto")!
    }

    var body: some View {
        Link(destination: Self.donateURL) {
            Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
        }
    }
}
#endif
