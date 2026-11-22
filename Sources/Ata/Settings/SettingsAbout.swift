#if os(macOS)
import SwiftUI

struct SettingsAboutPane: View {
    @State private var showingAcknowledgements = false
    @State private var acknowledgementsText = ""

    var body: some View {
        Form {
            Section {
                SettingsNote(L("Always tell the other participants that you are recording. Headphones help the transcript keep the speakers apart."))
                HStack(spacing: 10) {
                    Link(destination: Updater.shared.releasesPage.deletingLastPathComponent()) {
                        Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Spacer()
                    CoffeeButton()
                }
                .ataCaption()
                if let text = Acknowledgements.text() {
                    Button("Acknowledgements") {
                        acknowledgementsText = text
                        showingAcknowledgements = true
                    }
                }
            }
        }
        .settingsForm()
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsView(text: acknowledgementsText)
        }
    }
}
#endif
