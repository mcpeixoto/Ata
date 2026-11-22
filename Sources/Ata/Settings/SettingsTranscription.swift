#if os(macOS)
import SwiftUI

/// Model, name, language, dictionary, echo and the summary.
struct SettingsTranscriptionPane: View {
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.summarize) private var summarize = true
    @AppStorage(Pref.cancelEcho) private var cancelEcho = true
    @AppStorage(Pref.summaryTemplate) private var summaryTemplate = SummaryTemplate.standard.rawValue
    @AppStorage(Pref.dictionary) private var dictionary = ""
    @State private var showingTemplates = false

    var body: some View {
        Form {
            Section("Transcription") {
                LocalModelRows()
                SettingsNote(L("Whisper Large is the model Ata uses. It runs on this Mac, and nothing you record is uploaded."))
                TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
                Picker("Language", selection: $language) {
                    Text("Automatic").tag("auto")
                    ForEach(Pref.languageChoices, id: \.code) { choice in
                        Text(choice.name).tag(choice.code)
                    }
                }
                TextField("Names and words to spell right", text: $dictionary, prompt: Text("Copilot, Attio, Bernardo"))
                SettingsNote(L("People you have named are included on their own. In a summary, they are spelled as written here."))
                Toggle("Remove the others' voices from your microphone", isOn: $cancelEcho)
                SettingsNote(L("For calls without headphones: Ata takes what your Mac played out of your microphone before transcribing. The recording itself is not changed."))
                Toggle("Add an AI summary with the key points", isOn: $summarize)
                if summarize {
                    Picker("Note template", selection: $summaryTemplate) {
                        ForEach(SummaryTemplate.allCases) { template in
                            Text(template.title).tag(template.rawValue)
                        }
                    }
                    Button("Your templates") { showingTemplates = true }
                    summaryFootnote
                }
            }
        }
        .settingsForm()
        .sheet(isPresented: $showingTemplates) {
            TemplateListView()
        }
    }

    @ViewBuilder
    private var summaryFootnote: some View {
        if AppleModel.isAvailable {
            SettingsNote(L("Written on this Mac by Apple Intelligence. Nothing leaves it."))
        } else {
            if let reason = AppleModel.unavailableReason {
                SettingsNote(reason, tone: .warning)
            }
            Button("Turn on Apple Intelligence") { SetupModel.openAppleIntelligence() }
        }
    }
}
#endif
