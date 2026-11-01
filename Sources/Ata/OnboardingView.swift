import AppKit
import SwiftUI

/// The welcome window: three short steps, with Whisper Large downloading below
/// them the whole time. Everything else has a default and lives in Settings.
struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var setup: SetupModel
    @AppStorage(Pref.onboarded) private var onboarded = false
    @AppStorage(Pref.loginItemOffered) private var loginItemOffered = false
    @State private var apple = AppleModel.state
    @State private var summariesPassed = false
    @State private var moveError: String?
    @StateObject private var trial = TrialRecording()

    /// The window's height, and which step to show. Only the snapshot renderer sets these.
    var height: CGFloat = 520
    var previewStep: SetupStep?

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var step: SetupStep {
        previewStep ?? SetupStep.current(mic: setup.mic, systemAudioMissing: setup.systemAudioMissing,
                                         apple: apple, summariesPassed: summariesPassed)
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: 14) {
                if !settled { moveNotice }
                switch step {
                case .recording: recordingStep
                case .summaries: summariesStep
                case .done: doneStep
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .frame(width: 520, height: height)
        .onAppear {
            setup.refresh()
            apple = AppleModel.state
            guard !Snapshots.rendering else { return }
            // A menu bar app that is not open at login is easy to lose. Offered
            // once, here and visibly, so turning it off stays off.
            if !onboarded, !loginItemOffered {
                loginItemOffered = true
                if !setup.launchAtLogin { setup.setLaunchAtLogin(true) }
            }
        }
        .onReceive(poll) { _ in
            setup.refresh()
            apple = AppleModel.state
        }
    }

    // MARK: Steps

    private var recordingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(1, L("Allow recording"))
            Text("Ata records your microphone and the sound your Mac plays, never your screen.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if micDenied {
                advice(L("Turn on Ata under Microphone in the settings that open."))
            } else if setup.systemAudioStatus == .denied {
                advice(L("Turn on Ata under \"System Audio Recording Only\" in the settings that open."))
            } else {
                Text("macOS asks three times: microphone, notifications, system audio. After the last one Ata restarts itself once, and comes back here.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(micDenied || setup.systemAudioStatus == .denied ? L("Open Settings") : L("Allow")) {
                setup.allowRecording()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }

    private var micDenied: Bool {
        !setup.mic && !AVAuthorization.micUndetermined
    }

    private var summariesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(2, L("Summaries"))
            Text("Apple Intelligence writes each meeting's decisions and action items, on this Mac. Nothing leaves it.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if apple == .preparing {
                advice(L("Apple Intelligence is still getting ready. Your summaries will be written once it is."))
            } else {
                advice(L("Turn it on in System Settings. Meetings you record before then get their summary afterwards."))
            }
            HStack {
                if apple == .off {
                    Button("Open Settings") { SetupModel.openAppleIntelligence() }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                Button(apple == .off ? L("Later") : L("Continue")) { summariesPassed = true }
                    .controlSize(.large)
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle(3, L("You're set"))
            Label {
                Text("Ata is the waveform at the top right of your screen. It stays there when you close this window, and asks when it notices a meeting.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "waveform").foregroundStyle(Theme.meTint)
            }
            if let shortcut = Shortcut(Pref.d.string(forKey: Pref.recordShortcut) ?? "") {
                Label(L("Record from anywhere with %@.", shortcut.display), systemImage: "command")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            trialRow
            Toggle(isOn: Binding(get: { setup.launchAtLogin }, set: { setup.setLaunchAtLogin($0) })) {
                Text("Open Ata at login").font(.system(size: 13))
            }
            .toggleStyle(AppSwitchStyle())
            if apple == .unsupported {
                Text("This Mac can't write summaries, because they need Apple Intelligence. Transcripts work the same.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var trialRow: some View {
        switch trial.phase {
        case .idle:
            Button("Try a 10-second test") { trial.start(store) }
                .disabled(store.phase != .idle)
        case .running:
            VStack(alignment: .leading, spacing: 4) {
                meter(L("Microphone"), store.micLevel)
                meter(L("This Mac"), store.systemLevel)
            }
        case .finished(let heardMic, let heardMac):
            Label(heardMic
                  ? (heardMac ? L("Ata heard you and your Mac. The test was not saved.")
                              : L("Ata heard you. Nothing was playing on your Mac. The test was not saved."))
                  : L("Ata didn't hear your microphone. Check it isn't muted, and try again."),
                  systemImage: heardMic ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(heardMic ? Color.green : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func meter(_ title: String, _ level: Float) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            ProgressView(value: Double(min(max(level, 0), 1)))
        }
    }

    // MARK: Pieces

    private func stepTitle(_ number: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Step %d of 3", number)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 20, weight: .bold, design: .rounded))
        }
    }

    private func advice(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var settled: Bool {
        Paths.overridden || Snapshots.rendering || InstallLocation.isSettled(Bundle.main.bundlePath, home: NSHomeDirectory())
    }

    private var moveNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(moveError ?? L("Ata needs to be in Applications to open at login and to update itself."))
                .font(.system(size: 12)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Move to Applications") { moveToApplications() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private func moveToApplications() {
        let target = URL(fileURLWithPath: "/Applications/Ata.app")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                moveError = L("There is already an Ata in Applications. Open that one, or replace it in the Finder.")
                return
            }
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: target)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(target.path)\""]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Ata: could not move to Applications: \(error)")
            moveError = L("Ata could not move itself. Drag it into Applications in the Finder, and open it from there.")
        }
    }

    private var hero: some View {
        ZStack {
            Theme.brand.opacity(0.9)
            VStack(spacing: 6) {
                AppGlyph(size: 44)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.35)))
                Text("Welcome to Ata").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.top, 14)
        }
        .frame(height: 124)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            modelStatus
            Spacer()
            if step == .done {
                Button("Start") {
                    onboarded = true
                    store.setupChanged()
                    WindowManager.shared.closeOnboarding()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var modelStatus: some View {
        if setup.model {
            Label(L("Whisper Large is ready"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        } else if let p = setup.downloadProgress {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Downloading Whisper Large, %d%%", Int(p * 100))).font(.system(size: 11)).foregroundStyle(.secondary)
                ProgressView(value: p).frame(width: 220)
            }
        } else if let error = setup.downloadError {
            Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { setup.downloadModels() }
        } else {
            Text(L("Whisper Large (%@) downloads after this step.", LocalModel.current.sizeText))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Ten seconds of real recording to prove both sides arrive. It goes through the
/// same path as a meeting and is discarded at the end.
@MainActor
final class TrialRecording: ObservableObject {
    enum Phase: Equatable {
        case idle, running, finished(heardMic: Bool, heardMac: Bool)
    }
    @Published private(set) var phase = Phase.idle

    func start(_ store: AppStore) {
        guard phase == .idle else { return }
        store.startRecording(app: nil) { [weak self] started in
            guard started, let self else { return }
            self.phase = .running
            Task { await self.run(store) }
        }
    }

    private func run(_ store: AppStore) async {
        var peakMic: Float = 0
        var peakMac: Float = 0
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            peakMic = max(peakMic, store.micLevel)
            peakMac = max(peakMac, store.systemLevel)
        }
        store.discardRecording()
        phase = .finished(heardMic: peakMic >= 0.05, heardMac: peakMac >= 0.01)
    }
}
