import SwiftUI

/// The iPhone's settings: fewer than the Mac's, because the phone records one
/// microphone and transcribes on the device only.
struct PhoneSettings: View {
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.recogniseVoices) private var recogniseVoices = false
    @AppStorage(Pref.keepAudio) private var keepAudio = true
    @StateObject private var cloud = CloudSync.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var iCloudFootnote: String {
        if let problem = cloud.problem { return problem }
        if cloud.copying {
            return L("Your meetings stay on this iPhone until their copy in iCloud is checked and uploaded.")
        }
        if cloud.isOn {
            return L("Your meetings and voices are in iCloud Drive, and show up in Ata on your Mac too. Turned off, Ata goes back to the meetings on this iPhone; what's in iCloud stays there.")
        }
        switch cloud.status {
        case .checking:
            return L("Checking iCloud…")
        case .available:
            return L("Copies your meetings and voices into iCloud Drive, so Ata on your Mac shows them too.")
        case .signedOut, .notOnThisMac:
            return L("Sign in to iCloud and turn on iCloud Drive for Ata in Settings to use this.")
        }
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
                    Text(cloud.inCloud
                         ? L("Tells the people in a conversation apart and learns their voices, so you name each one once. Fingerprints stay in your iCloud, with your meetings.")
                         : L("Tells the people in a conversation apart and learns their voices, so you name each one once. Fingerprints stay on this iPhone."))
                }

                Section {
                    Toggle("Keep meetings in iCloud", isOn: Binding(
                        get: { cloud.isOn || cloud.copying },
                        set: { on in
                            if on { cloud.turnOn() } else { cloud.turnOff() }
                        }))
                        .disabled(!cloud.isOn && !cloud.copying && cloud.status != .available)
                    if cloud.copying && cloud.total > 0 {
                        ProgressView(value: Double(cloud.copied), total: Double(cloud.total)) {
                            Text(L("Copying your meetings into iCloud… %d of %d", cloud.copied, cloud.total))
                                .font(.footnote)
                        }
                    }
                } footer: {
                    Text(iCloudFootnote)
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
            .onAppear { cloud.recheck() }
        }
    }
}
