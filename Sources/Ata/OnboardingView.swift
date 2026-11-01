import AppKit
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @AppStorage(Pref.autoDetect) private var autoDetect = true
    @AppStorage(Pref.autoStart) private var autoStart = false
    @AppStorage(Pref.onboarded) private var onboarded = false
    @State private var appleReady = AppleModel.isAvailable

    /// The window's height. Only the snapshot renderer asks for a taller one.
    var height: CGFloat = 700

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
                        CheckRow(ok: !setup.systemAudioMissing, title: L("System audio"),
                                 detail: setup.systemAudioStatus == .denied
                                    ? L("Turn on Ata under \"System Audio Recording Only\" in the settings that open.")
                                    : L("To record the other participants. Only the sound — never your screen.")) {
                            Button("Allow") { setup.requestSystemAudio() }
                        }
                        Divider()
                        CheckRow(ok: setup.notifications, title: L("Notifications"),
                                 detail: L("Tells you when a meeting is detected and when a transcript is ready."),
                                 optional: true) {
                            Button("Allow") { setup.requestNotifications() }
                        }
                        Divider()
                        CheckRow(ok: setup.calendar, title: L("Calendar"),
                                 detail: setup.calendarDenied
                                    ? L("Turn Ata on under Calendars in the settings that open.")
                                    : L("So Ata can offer to record a meeting before it starts, and file it under the event's title. Read only — Ata never changes a calendar."),
                                 optional: true) {
                            Button("Allow") { setup.requestCalendar() }
                        }
                    }

                    section(L("Where Ata lives")) {
                        Text("Ata stays in the menu bar, not the Dock. Close this window and it keeps running up there. Quit Ata from the menu bar icon when you want it to stop.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section(L("Transcription")) {
                        localRows
                        Text("Whisper Large runs on this Mac. Nothing you record is uploaded.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section(L("Summaries")) {
                        CheckRow(ok: appleReady, title: L("Apple Intelligence"),
                                 detail: appleReady
                                    ? L("Writes the summary — decisions and action items — on this Mac. Nothing leaves it.")
                                    : (AppleModel.unavailableReason
                                       ?? L("Turn on Apple Intelligence in System Settings and Ata can write the summary."))) {
                            if !appleReady {
                                Button("Turn on") { SetupModel.openAppleIntelligence() }
                            }
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
        .onAppear {
            setup.refresh()
            appleReady = AppleModel.isAvailable
            guard !Snapshots.rendering else { return }
            // A menu bar app that is not open at login is easy to lose.
            if !onboarded, !setup.launchAtLogin { setup.setLaunchAtLogin(true) }
            if !setup.model { setup.downloadModels() }
        }
        .onReceive(poll) { _ in
            setup.refresh()
            appleReady = AppleModel.isAvailable
        }
        .onChange(of: setup.ready) { _, ready in if ready { store.setupChanged() } }
    }

    /// The model, which downloads once.
    @ViewBuilder
    private var localRows: some View {
        CheckRow(ok: setup.model, title: L("Whisper model: %@", LocalModel.current.title),
                 detail: setup.downloadError
                    ?? L("%@, downloaded once. %@", LocalModel.current.sizeText, LocalModel.current.detail)) {
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

    private var hero: some View {
        ZStack {
            Theme.brand.opacity(0.9)
            VStack(spacing: 10) {
                AppGlyph(size: 64)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.35)))
                Text("Welcome to Ata").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text("Record and transcribe any meeting. Ata lives in your menu bar.")
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
