import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @AppStorage(Pref.autoDetect) private var autoDetect = true
    @AppStorage(Pref.autoStart) private var autoStart = false
    @AppStorage(Pref.onboarded) private var onboarded = false
    @AppStorage(Pref.engine) private var engine = Engine.local.rawValue
    @State private var apiKey = ""

    /// The window's height. Only the snapshot renderer asks for a taller one.
    var height: CGFloat = 640

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(L("Permissions")) {
                        CheckRow(ok: setup.mic, title: L("Microphone"),
                                 detail: L("To record your voice.")) {
                            Button("Allow") { setup.requestMic() }
                        }
                        Divider()
                        CheckRow(ok: setup.screen, title: L("System audio"),
                                 detail: setup.screenNeedsRelaunch
                                    ? L("Enable Ata in the list, then reopen the app.")
                                    : L("To record the other participants. macOS calls this \"Screen & System Audio Recording\"; Ata only uses the sound.")) {
                            HStack {
                                if setup.screenNeedsRelaunch {
                                    Button("Reopen") { setup.relaunch() }
                                }
                                Button("Allow") { setup.requestScreen() }
                            }
                        }
                        Divider()
                        CheckRow(ok: setup.notifications, title: L("Notifications"),
                                 detail: L("Tells you when a meeting is detected and when a transcript is ready."),
                                 optional: true) {
                            Button("Allow") { setup.requestNotifications() }
                        }
                    }

                    section(L("Transcription")) {
                        Picker("", selection: Binding(
                            get: { engine },
                            set: { engine = $0; setup.setEngine(Engine(rawValue: $0) ?? .local) })) {
                            Text("On this Mac — private, free, 1.6 GB download")
                                .tag(Engine.local.rawValue)
                            Text("OpenAI API — nothing to install, you pay per minute")
                                .tag(Engine.openAI.rawValue)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .font(.system(size: 12))

                        Divider()

                        if engine == Engine.openAI.rawValue {
                            openAIRows
                        } else {
                            localRows
                        }
                    }

                    section(L("Behaviour")) {
                        Toggle(isOn: Binding(get: { autoDetect }, set: { store.setAutoDetect($0); autoDetect = $0 })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detect meetings automatically").font(.system(size: 13, weight: .semibold))
                                Text("When Slack, Zoom, Meet, Teams… start using the microphone.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(AppSwitchStyle())
                        if autoDetect {
                            Picker("When a meeting is detected", selection: $autoStart) {
                                Text("Ask me with a notification").tag(false)
                                Text("Start recording").tag(true)
                            }
                            .pickerStyle(.radioGroup)
                            .font(.system(size: 12))
                        }
                        Divider()
                        Toggle(isOn: Binding(get: { setup.launchAtLogin }, set: { setup.setLaunchAtLogin($0) })) {
                            Text("Open Ata at login").font(.system(size: 13, weight: .semibold))
                        }
                        .toggleStyle(AppSwitchStyle())
                    }
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 520, height: height)
        .onAppear { setup.refresh() }
        .onReceive(poll) { _ in setup.refresh() }
        .onChange(of: setup.ready) { _, ready in if ready { store.setupChanged() } }
    }

    /// whisper.cpp + the model, for the local engine.
    @ViewBuilder
    private var localRows: some View {
        CheckRow(ok: setup.whisper, title: L("whisper.cpp engine"),
                 detail: setup.whisperStatus ?? (setup.hasBrew
                    ? L("Installed with Homebrew. Runs on your Mac's GPU.")
                    : L("Needs Homebrew (brew.sh)."))) {
            if setup.installingWhisper {
                ProgressView().controlSize(.small)
            } else {
                Button(setup.hasBrew ? L("Install") : L("Open brew.sh")) { setup.installWhisper() }
            }
        }
        Divider()
        CheckRow(ok: setup.model, title: L("Whisper large-v3-turbo model"),
                 detail: setup.downloadError ?? L("1.6 GB, downloaded once. Excellent in English and Portuguese.")) {
            if let p = setup.downloadProgress {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: p).frame(width: 110)
                    Text("\(Int(p * 100))%").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                Button(setup.downloadError == nil ? L("Download") : L("Try again")) { setup.downloadModels() }
            }
        }
    }

    /// API key entry, for the OpenAI engine.
    @ViewBuilder
    private var openAIRows: some View {
        CheckRow(ok: setup.hasOpenAIKey, title: L("OpenAI API key"),
                 detail: keyDetail) {
            if setup.keyCheck == .checking {
                ProgressView().controlSize(.small)
            } else {
                Button(setup.hasOpenAIKey ? L("Replace") : L("Save")) {
                    setup.setOpenAIKey(apiKey)
                    apiKey = ""
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        SecureField("sk-…", text: $apiKey)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                setup.setOpenAIKey(apiKey)
                apiKey = ""
            }
        Text("Your audio is uploaded to OpenAI for transcription. The key is stored in your login keychain.")
            .font(.system(size: 11)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var keyDetail: String {
        switch setup.keyCheck {
        case .failed(let message): return message
        case .ok: return L("Key works.")
        case .checking: return L("Checking…")
        case .idle:
            return setup.hasOpenAIKey
                ? L("Stored in your login keychain.")
                : L("Create one at platform.openai.com, then paste it below.")
        }
    }

    private var hero: some View {
        ZStack {
            Theme.brand.opacity(0.9)
            VStack(spacing: 10) {
                AppGlyph(size: 64)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.35)))
                Text("Welcome to Ata").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Record and transcribe any meeting, right on your Mac.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 18)
        }
        .frame(height: 190)
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
    }

    private var footer: some View {
        HStack {
            if setup.ready {
                Label("Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Text(setup.missingSummary ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(setup.ready ? L("Start") : L("Close")) {
                onboarded = true
                store.setupChanged()
                WindowManager.shared.closeOnboarding()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }
}
