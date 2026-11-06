import SwiftUI

/// Where the iCloud Drive switch is. iOS asks no question for it and lets no app
/// turn it on, so this is the closest Ata can get to a permission prompt: the
/// way there, and the setting turning itself on once Ata comes back to the front.
struct ICloudHelpSheet: View {
    @ObservedObject var cloud: CloudSync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, Text("Open Settings and tap your name at the top."))
                    step(2, Text("Tap iCloud, then iCloud Drive."))
                    step(3, Text("Turn on Sync this iPhone."))
                    step(4, Text("Turn on Ata in the list of apps below it."))
                } header: {
                    Text("Turn on iCloud Drive for Ata")
                } footer: {
                    Text("Apple keeps this switch in Settings, so Ata can't flip it for you. When you come back, Ata starts copying your meetings on its own.")
                }
            }
            .navigationTitle("iCloud")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") {
                        cloud.stopWaiting()
                        dismiss()
                    }
                }
            }
            // iCloud answered while this was open: nothing left to explain.
            .onChange(of: cloud.waitingForICloud) { _, waiting in
                if !waiting { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func step(_ number: Int, _ text: Text) -> some View {
        Label {
            text
        } icon: {
            Image(systemName: "\(number).circle.fill")
                .foregroundStyle(.tint)
        }
    }
}
