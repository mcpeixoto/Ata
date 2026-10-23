import SwiftUI

/// The iPhone's settings: fewer than the Mac's, because the phone records one
/// microphone and transcribes on the device only.
struct PhoneSettings: View {
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.recogniseVoices) private var recogniseVoices = false
    @AppStorage(Pref.keepAudio) private var keepAudio = true
    @AppStorage(Pref.iCloudSync) private var iCloudSync = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
                        .textContentType(.givenName)
                } footer: {
                    Text("How you appear in transcripts.")
                }

                Section {
                    Picker("Language", selection: $language) {
                        Text("Automatic").tag("auto")
                        Text("English").tag("en")
                        Text("Português").tag("pt")
                        Text("Español").tag("es")
                        Text("Français").tag("fr")
                        Text("Deutsch").tag("de")
                        Text("Italiano").tag("it")
                    }
                    Toggle("Keep the audio after transcribing", isOn: $keepAudio)
                } header: {
                    Text("Transcription")
                }

                Section {
                    Toggle("Recognise voices", isOn: $recogniseVoices)
                } footer: {
                    Text("Tells the people in a conversation apart and learns their voices, so you name each one once. Fingerprints stay on this iPhone.")
                }

                Section {
                    Toggle("Keep meetings in iCloud", isOn: $iCloudSync)
                        .disabled(true)
                } footer: {
                    Text("Not available yet. When it is, your meetings appear in Ata on your Mac too, through iCloud Drive.")
                }

                Section {
                    LabeledContent("Version", value: version)
                    if let url = URL(string: "https://github.com/mcpeixoto/Ata") {
                        Link("Source code", destination: url)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
