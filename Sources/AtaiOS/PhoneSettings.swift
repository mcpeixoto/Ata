import SwiftUI

/// The iPhone's settings: fewer than the Mac's, because the phone records one
/// microphone and transcribes on the device only.
struct PhoneSettings: View {
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.recogniseVoices) private var recogniseVoices = true
    @AppStorage(Pref.keepAudio) private var keepAudio = true
    @AppStorage(Pref.shareUsage) private var shareUsage = true
    @AppStorage(Pref.summarize) private var summarize = true
    @AppStorage(Pref.defaultCategory) private var defaultCategory = ""
    @StateObject private var cloud = CloudSync.shared
    @ObservedObject private var pro = ProStore.shared
    @EnvironmentObject private var store: PhoneStore
    @State private var managingSubscription = false
    @State private var showingICloudHelp = Snapshots.rendering && Snapshots.screen == .iCloudHelp
    @State private var showingAcknowledgements = false
    @State private var acknowledgementsText = ""

    /// Why no summary will appear, when none will. Summaries are on by default on
    /// the iPhone (`Pref.platformDefaults`), and before this they could silently
    /// never arrive: Apple Intelligence off, and no way on the phone to see why.
    private var summaryFootnote: String {
        if let reason = AppleModel.unavailableReason {
            return reason
        }
        return L("Ata writes a short summary of each meeting with Apple Intelligence, on this iPhone. Nothing leaves it.")
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var iCloudFootnote: String {
        if let problem = cloud.problem { return problem }
        if cloud.copyingOut {
            return L("Ata keeps using iCloud until every meeting is copied to this iPhone and checked. Nothing is removed from iCloud.")
        }
        if cloud.copying {
            return L("Your meetings stay on this iPhone until their copy in iCloud is checked and uploaded.")
        }
        if cloud.isOn {
            return L("Your meetings and voices are in iCloud Drive, and show up in Ata on your Mac too. Turned off, Ata goes back to the meetings on this iPhone; what's in iCloud stays there.")
        }
        if cloud.waitingForICloud {
            return L("Waiting for iCloud Drive. Turn it on for Ata in Settings, and this finishes by itself.")
        }
        switch cloud.status {
        case .checking:
            return L("Checking iCloud…")
        case .available:
            return L("Copies your meetings and voices into iCloud Drive, so Ata on your Mac shows them too.")
        case .signedOut, .notOnThisMac:
            return L("iCloud Drive is off for Ata. Turn this on to see where to switch it on.")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
                        .textContentType(.givenName)
                } header: {
                    // A Form hides a text field's label, so without this the
                    // first row is a bare name with nothing saying what it is.
                    Text("Your name")
                } footer: {
                    Text("How you appear in transcripts.")
                }

                Section {
                    Picker("Language", selection: $language) {
                        Text("Automatic").tag("auto")
                        ForEach(Pref.languageChoices, id: \.code) { choice in
                            Text(choice.name).tag(choice.code)
                        }
                    }
                    Toggle("Keep the audio after transcribing", isOn: $keepAudio)
                } header: {
                    Text("Transcription")
                }

                Section {
                    Picker("New meetings", selection: $defaultCategory) {
                        Text("No category").tag("")
                        ForEach(MeetingCategory.allCases) { c in Text(c.name).tag(c.rawValue) }
                    }
                } header: {
                    Text("Work and personal")
                } footer: {
                    Text("What a new recording is filed under. You can change it in the meeting.")
                }

                Section {
                    Toggle("Add an AI summary", isOn: $summarize)
                } footer: {
                    Text(summaryFootnote)
                }

                Section {
                    Toggle("Recognise voices", isOn: $recogniseVoices)
                } footer: {
                    Text(cloud.inCloud
                         ? L("Tells the people in a conversation apart and learns their voices, so you name each one once. Fingerprints stay in your iCloud, with your meetings.")
                         : L("Tells the people in a conversation apart and learns their voices, so you name each one once. Fingerprints stay on this iPhone."))
                }

                Section {
                    LabeledContent("Status", value: pro.isPro
                                   ? L("Active")
                                   : L("%d of %d free meetings left this month",
                                       FreeQuota.remaining(used: store.freeUsed), FreeQuota.limit))
                    if pro.isPro {
                        Button("Manage subscription") { managingSubscription = true }
                    } else {
                        Button("Upgrade to Ata Pro") { PhoneNavigation.shared.showPaywall() }
                    }
                    Button("Restore Purchases") { Task { await pro.restore() } }
                        .disabled(pro.purchasing)
                } header: {
                    Text("Ata Pro")
                } footer: {
                    Text(pro.message ?? L("Unlimited meetings on this iPhone. Ata for Mac is free and stays free."))
                }

                Section {
                    Toggle("Keep meetings in iCloud", isOn: Binding(
                        get: { (cloud.isOn || cloud.copying || cloud.waitingForICloud) && !cloud.copyingOut },
                        set: { on in
                            if on {
                                if !cloud.requestTurnOn() { showingICloudHelp = true }
                            } else if cloud.waitingForICloud {
                                cloud.stopWaiting()
                            } else {
                                cloud.turnOff()
                            }
                        }))
                    if cloud.copying && cloud.total > 0 {
                        ProgressView(value: Double(cloud.copied), total: Double(cloud.total)) {
                            Text(cloud.copyingOut
                                 ? L("Copying your meetings from iCloud… %d of %d", cloud.copied, cloud.total)
                                 : L("Copying your meetings into iCloud… %d of %d", cloud.copied, cloud.total))
                                .font(.footnote)
                        }
                    }
                } footer: {
                    Text(iCloudFootnote)
                }

                Section {
                    Toggle("Share anonymous usage stats", isOn: $shareUsage)
                } footer: {
                    Text("Once a day: the app version, your country and how many minutes you recorded. Never your audio, transcripts or names.")
                }

                Section {
                    LabeledContent("Version", value: version)
                    // The support page rather than the repository: the repository
                    // carries a donation link, which App Review treats as an
                    // outside purchase.
                    if let url = URL(string: "https://mcpeixoto.github.io/Ata/") {
                        Link("Help", destination: url)
                    }
                    Link("Terms of Use", destination: Paywall.termsURL)
                    if let url = URL(string: "https://mcpeixoto.github.io/Ata/privacy/") {
                        Link("Privacy Policy", destination: url)
                    }
                    if let text = Acknowledgements.text() {
                        Button("Acknowledgements") {
                            acknowledgementsText = text
                            showingAcknowledgements = true
                        }
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                cloud.recheck()
                // A purchase or restore message from last time is not this visit's.
                pro.message = nil
            }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .sheet(isPresented: $showingICloudHelp) {
                ICloudHelpSheet(cloud: cloud)
            }
            .sheet(isPresented: $showingAcknowledgements) {
                AcknowledgementsView(text: acknowledgementsText)
            }
        }
    }
}
