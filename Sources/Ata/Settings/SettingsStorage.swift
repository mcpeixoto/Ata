#if os(macOS)
import AppKit
import SwiftUI

/// Audio, retention, iCloud and the meetings folder.
struct SettingsStoragePane: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var cloud = CloudSync.shared
    @AppStorage(Pref.keepAudio) private var keepAudio = true
    @AppStorage(Pref.compressAudio) private var compressAudio = true
    @AppStorage(Pref.audioRetentionDays) private var audioRetentionDays = 0
    @State private var pendingRetention: Int?

    var body: some View {
        Form {
            audioSection
            iCloudSection
            Section {
                LabeledContent("Meetings folder") {
                    Button("Open") { NSWorkspace.shared.open(Paths.meetingsDir) }
                }
            }
        }
        .settingsForm()
    }

    private var audioSection: some View {
        Section("Audio") {
            Toggle("Keep the audio after transcribing", isOn: $keepAudio)
            SettingsNote(keepAudio
                 ? (compressAudio
                    ? L("Recordings are kept next to each transcript, about 10× smaller than the raw WAV.")
                    : L("Recordings are kept as WAV — roughly 115 MB per hour, per track."))
                 : L("Audio is deleted once the transcript is written. A failed transcription never deletes it."))
            Picker("Delete saved audio after", selection: Binding(
                get: { audioRetentionDays },
                set: { proposeRetention($0) })) {
                Text("Never").tag(0)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .disabled(!keepAudio)
            .confirmationDialog(
                L("Delete audio older than %@ now? Transcripts and notes stay.",
                  AudioRetention.name(for: pendingRetention ?? 7)),
                isPresented: Binding(get: { pendingRetention != nil },
                                     set: { if !$0 { pendingRetention = nil } }),
                titleVisibility: .visible) {
                Button(L("Delete audio"), role: .destructive) {
                    if let days = pendingRetention { applyRetention(days) }
                    pendingRetention = nil
                }
                Button(L("Cancel"), role: .cancel) { pendingRetention = nil }
            }
            LabeledContent("Kept on disk") {
                Text(store.storageText)
            }
        }
    }

    /// A shorter window deletes audio that is already on disk. Ask first; a longer
    /// one, or a shorter one with nothing old enough, just takes effect.
    private func proposeRetention(_ days: Int) {
        let previous = audioRetentionDays
        guard AudioRetention.isShorter(days, than: previous) else {
            applyRetention(days)
            return
        }
        Task { @MainActor in
            let deletes = await store.retentionDeletesExistingAudio(days: days)
            if deletes {
                pendingRetention = days
            } else {
                applyRetention(days)
            }
        }
    }

    private func applyRetention(_ days: Int) {
        audioRetentionDays = days
        store.pruneOldAudio()
    }

    private var iCloudSection: some View {
        Section("iCloud") {
            Toggle("Keep meetings in iCloud", isOn: Binding(
                get: { (cloud.isOn || cloud.copying) && !cloud.copyingOut },
                set: { on in
                    if on { cloud.turnOn() } else { cloud.turnOff() }
                }))
                .disabled(!cloud.isOn && !cloud.copying && cloud.status != .available)
            if cloud.copying && cloud.total > 0 {
                ProgressView(value: Double(cloud.copied), total: Double(cloud.total)) {
                    Text(cloud.copyingOut
                         ? L("Copying your meetings from iCloud… %d of %d", cloud.copied, cloud.total)
                         : L("Copying your meetings into iCloud… %d of %d", cloud.copied, cloud.total))
                        .ataCaption()
                }
            }
            SettingsNote(iCloudFootnote)
            if let originals = cloud.originals {
                LabeledContent("Originals on this Mac") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([originals]) }
                }
                SettingsNote(L("They were copied into iCloud and checked. Remove them when you no longer need them."))
            }
        }
    }

    private var iCloudFootnote: String {
        if let problem = cloud.problem { return problem }
        if cloud.copyingOut {
            return L("Ata keeps using iCloud until every meeting is copied to this Mac and checked. Nothing is removed from iCloud.")
        }
        if cloud.copying {
            return L("The originals stay where they are. Ata moves to the copy once every meeting is in iCloud and checked.")
        }
        if cloud.isOn {
            return L("Your meetings and voices are in iCloud Drive, and show up in Ata on your iPhone. Turned off, Ata goes back to the meetings on this Mac; what's in iCloud stays there.")
        }
        switch cloud.status {
        case .checking:
            return L("Checking iCloud…")
        case .available:
            return L("Copies your meetings and voices into iCloud Drive, so Ata on your iPhone shows them too. The originals stay on this Mac.")
        case .signedOut:
            return L("Sign in to iCloud and turn on iCloud Drive in System Settings to use this.")
        case .notOnThisMac:
            return L("Turn on “Keep meetings in iCloud” in Ata on your iPhone first. This Mac then uses the same folder.")
        }
    }
}
#endif
