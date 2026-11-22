import AppKit
import Combine
import SwiftUI

/// The welcome window: welcome, permissions, summaries (only when Apple
/// Intelligence can still be turned on), you, a test recording, done. Whisper
/// Large downloads below the steps the whole time. Everything else has a
/// default and lives in Settings.
struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var live = LiveValues.shared
    @EnvironmentObject var setup: SetupModel
    @AppStorage(Pref.onboarded) private var onboarded = false
    @AppStorage(Pref.shareUsage) private var shareUsage = true
    @AppStorage(Pref.loginItemOffered) private var loginItemOffered = false
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.calendarPrompt) private var calendarPrompt = false
    @State private var apple = AppleModel.state
    @State private var moveError: String?
    @State private var current: OnboardingStep?
    @StateObject private var trial = TrialRecording()

    /// The window's height, and which step to show. Only the snapshot renderer sets these.
    var height: CGFloat = 620
    var previewStep: OnboardingStep?
    /// What the Pro card on the last step opens. Track 2 wires it to the Mac paywall.
    var showPro: () -> Void = {}

    static let width: CGFloat = 560

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common)
    @State private var pollConnection: AnyCancellable?

    private var step: OnboardingStep {
        previewStep ?? current ?? .welcome
    }

    private var steps: [OnboardingStep] { OnboardingStep.sequence(apple: apple) }

    var body: some View {
        OnboardingScaffold(step: steps.firstIndex(of: step) ?? 0, count: steps.count,
                           back: backAction) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                if !settled { moveNotice }
                switch step {
                case .welcome: welcomeStep
                case .permissions: permissionsStep
                case .summaries: summariesStep
                case .you: youStep
                case .test: testStep
                case .done: doneStep
                }
            }
        } footer: {
            footer
        }
        .frame(width: Self.width, height: height)
        .tint(Theme.accent)
        .onAppear {
            setup.refresh()
            apple = AppleModel.state
            guard !Snapshots.rendering, previewStep == nil else { return }
            if current == nil {
                let stored = Pref.d.object(forKey: Pref.onboardingStep) == nil
                    ? nil : Pref.d.integer(forKey: Pref.onboardingStep)
                show(OnboardingStep.shown(persisted: stored, onboarded: onboarded, mic: setup.mic,
                                          systemAudioMissing: setup.systemAudioMissing, apple: apple))
            }
            guard pollConnection == nil else { return }
            // Held so disappearing can stop it. Not autoconnected: a closed window
            // must not keep asking.
            let connection = poll.connect()
            pollConnection = AnyCancellable { connection.cancel() }
        }
        .onDisappear {
            pollConnection?.cancel()
            pollConnection = nil
        }
        .onReceive(poll) { _ in
            setup.refresh()
            apple = AppleModel.state
        }
    }

    // MARK: Navigation

    /// Moves to `next`, remembers the furthest step reached so a restart comes
    /// back to it, and counts it for the anonymous funnel.
    private func go(to next: OnboardingStep) {
        withAnimation(.easeInOut(duration: 0.2)) { show(next) }
    }

    private func show(_ next: OnboardingStep) {
        current = next
        guard !Snapshots.rendering else { return }
        if next.rawValue > Pref.d.integer(forKey: Pref.onboardingStep) || Pref.d.object(forKey: Pref.onboardingStep) == nil {
            Pref.d.set(next.rawValue, forKey: Pref.onboardingStep)
        }
        Funnel.count(.onboardingStep(next.rawValue))
        if next == .you { offerLoginItem() }
    }

    private var backAction: (() -> Void)? {
        guard let previous = step.previous(apple: apple) else { return nil }
        return { go(to: previous) }
    }

    private func advance() { go(to: step.next(apple: apple)) }

    /// A menu bar app that is not open at login is easy to lose. On by default,
    /// once, on the step that shows the switch, so turning it off stays off.
    private func offerLoginItem() {
        guard !onboarded, !loginItemOffered else { return }
        loginItemOffered = true
        if !setup.launchAtLogin { setup.setLaunchAtLogin(true) }
    }

    private func finish() {
        onboarded = true
        store.setupChanged()
        WindowManager.shared.closeOnboarding()
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            WelcomeMock()
            Text("Meet Ata").ataLargeTitle()
            Text("Records your calls and writes them up, on this Mac.")
                .ataBody().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                point(L("Zoom, Meet, Teams or any other app"))
                point(L("Tells you and the others apart"))
                point(L("Transcribed on this Mac, not on a server"))
            }
        }
    }

    private func point(_ text: String) -> some View {
        Label {
            Text(verbatim: text).ataBody()
        } icon: {
            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Let Ata record your meetings").ataLargeTitle()
            Text("Ata records your microphone and the sound your Mac plays, never your screen.")
                .ataBody().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Card(padding: Theme.Space.s) {
                VStack(spacing: 0) {
                    CheckRow(ok: setup.mic, title: L("Microphone"),
                             detail: micDenied ? L("Turn on Ata under Microphone in the settings that open.")
                                               : L("Your side of the call.")) {
                        Button(micDenied ? L("Open Settings") : L("Allow")) { setup.requestMic() }
                    }
                    Divider()
                    CheckRow(ok: !setup.systemAudioMissing, title: L("Mac audio"),
                             detail: setup.systemAudioStatus == .denied
                                ? L("Turn on Ata under \"System Audio Recording Only\" in the settings that open.")
                                : L("The others, from whichever app the call is in.")) {
                        // Asked after the microphone, never before: the answer
                        // restarts Ata, and a tap started before it hears nothing.
                        Button(setup.systemAudioStatus == .denied ? L("Open Settings") : L("Allow")) {
                            setup.requestSystemAudio()
                        }
                        .disabled(!setup.mic)
                    }
                    Divider()
                    CheckRow(ok: setup.notifications, title: L("Notifications"),
                             detail: L("Optional. Ata tells you when it notices a meeting."), optional: true) {
                        Button(L("Allow")) { setup.requestNotifications() }
                    }
                }
            }
            if setup.systemAudioMissing {
                Text("Ata restarts once after you allow Mac audio. That is expected.")
                    .ataCallout().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var micDenied: Bool {
        !setup.mic && !AVAuthorization.micUndetermined
    }

    private var summariesStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("Summaries").ataLargeTitle()
            Text("Apple Intelligence writes each meeting's key points, on this Mac. Nothing leaves it.")
                .ataBody().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if apple == .preparing {
                advice(L("Apple Intelligence is still getting ready. Your summaries will be written once it is."))
            } else {
                advice(L("Turn it on in System Settings. Meetings you record before then get their summary afterwards."))
            }
            if apple == .off {
                Button("Open Settings") { SetupModel.openAppleIntelligence() }
                    .controlSize(.large)
            }
        }
    }

    private var youStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("A few choices").ataLargeTitle()
            Form {
                TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
                Picker("Language", selection: $language) {
                    Text("Automatic").tag("auto")
                    ForEach(Pref.languageChoices, id: \.code) { choice in
                        Text(choice.name).tag(choice.code)
                    }
                }
            }
            .formStyle(.columns)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Toggle(isOn: Binding(get: { calendarPrompt }, set: { on in
                    calendarPrompt = on
                    if on, !setup.calendar { setup.requestCalendar() } else { store.calendarChanged() }
                })) {
                    Text("Offer to record meetings on my calendar").ataBody()
                }
                .toggleStyle(AppSwitchStyle())
                if calendarPrompt, !setup.calendar {
                    HStack {
                        Spacer()
                        Button(setup.calendarDenied ? L("Open Settings") : L("Allow calendar")) { setup.requestCalendar() }
                    }
                }
                Toggle(isOn: Binding(get: { setup.launchAtLogin }, set: { setup.setLaunchAtLogin($0) })) {
                    Text("Open Ata at login").ataBody()
                }
                .toggleStyle(AppSwitchStyle())
                Toggle(isOn: $shareUsage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share anonymous usage stats").ataBody()
                        Text("Once a day: the app version, your country and how many minutes you recorded. Never your audio, transcripts or names.")
                            .ataCaption().foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(AppSwitchStyle())
            }
        }
    }

    private var testStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Try a 10-second test").ataLargeTitle()
            Text("Say a few words and play something on your Mac. Nothing is saved.")
                .ataBody().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                HeroRecordButton(size: 64, state: trialButtonState) { trial.start(store) }
                    .disabled(store.phase != .idle || trial.phase == .running)
                Spacer()
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                LevelBar(title: L("Microphone"), level: trial.phase == .running ? store.micLevel : 0, tint: Theme.me)
                LevelBar(title: L("This Mac"), level: trial.phase == .running ? store.systemLevel : 0, tint: Theme.others)
            }
            if case .finished(let heardMic, let heardMac) = trial.phase {
                Label(heardMic
                      ? (heardMac ? L("Ata heard you and your Mac. The test was not saved.")
                                  : L("Ata heard you. Nothing was playing on your Mac. The test was not saved."))
                      : L("Ata didn't hear your microphone. Check it isn't muted, and try again."),
                      systemImage: heardMic ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .ataCallout()
                    .foregroundStyle(heardMic ? Color.green : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trialButtonState: HeroRecordButton.Phase {
        switch trial.phase {
        case .idle: return store.phase == .idle ? .idle : .busy
        case .running: return .recording
        case .finished: return store.phase == .idle ? .idle : .busy
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("You're set").ataLargeTitle()
            MenuBarCallout()
            Label {
                Text("Ata is the waveform at the top right of your screen. It stays there when you close this window, and asks when it notices a meeting.")
                    .ataBody().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "waveform").foregroundStyle(Theme.meTint)
            }
            if let shortcut = Shortcut(Pref.d.string(forKey: Pref.recordShortcut) ?? "") {
                Label(L("Record from anywhere with %@.", shortcut.display), systemImage: "command")
                    .ataCallout().foregroundStyle(.secondary)
            }
            if FreeQuota.appliesOnMac {
                Button(action: showPro) {
                    Card {
                        HStack {
                            Text(L("%d minutes a month are free. Ata Pro removes the limit.", FreeQuota.limitMinutes))
                                .ataCallout()
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: Theme.Space.s)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if apple == .unsupported {
                Text("This Mac can't write summaries, because they need Apple Intelligence. Transcripts work the same.")
                    .ataCaption().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if step != .welcome { modelStatus }
            Spacer(minLength: Theme.Space.s)
            switch step {
            case .welcome:
                primary(L("Get started")) { advance() }
            case .permissions:
                if !setup.mic || !setup.systemAudioMissing {
                    primary(L("Continue"), enabled: setup.mic && !setup.systemAudioMissing) { advance() }
                } else {
                    Button(L("Continue without Mac audio")) { advance() }
                        .buttonStyle(.link)
                }
            case .summaries:
                primary(apple == .off ? L("Later") : L("Continue")) { advance() }
            case .you:
                primary(L("Continue")) { advance() }
            case .test:
                if case .finished = trial.phase {} else {
                    Button(L("Skip")) { advance() }
                        .buttonStyle(.link)
                        .disabled(trial.phase == .running)
                }
                primary(L("Continue"), enabled: trial.phase != .running) { advance() }
            case .done:
                primary(L("Start")) { finish() }
            }
        }
    }

    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).ataHeadline()
        }
        .buttonStyle(PrimaryButtonStyle())
        .frame(width: 160)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    @ViewBuilder
    private var modelStatus: some View {
        if setup.model {
            Label(L("Whisper Large is ready"), systemImage: "checkmark.circle.fill")
                .ataCallout().foregroundStyle(.green)
        } else if let p = setup.downloadProgress {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Downloading Whisper Large, %d%%", Int(p * 100))).ataCaption().foregroundStyle(.secondary)
                ProgressView(value: p).frame(width: 200)
            }
        } else if let error = setup.downloadError {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error).ataCaption()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Theme.danger)
            Button("Try again") { setup.downloadModels() }
        } else {
            Text(L("Whisper Large (%@) downloads after this step.", LocalModel.current.sizeText))
                .ataCaption().foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func advice(_ text: String) -> some View {
        Text(text).ataCallout().foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var settled: Bool {
        Paths.overridden || Snapshots.rendering || InstallLocation.isSettled(Bundle.main.bundlePath, home: NSHomeDirectory())
    }

    private var moveNotice: some View {
        Banner(kind: moveError == nil ? .warning : .danger,
               mark: .symbol("exclamationmark.triangle.fill"),
               title: Text(verbatim: moveError ?? L("Ata needs to be in Applications to open at login and to update itself."))) {
            Button("Move to Applications") { moveToApplications() }
        }
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
}

/// One input's loudness during the test, in that side's colour.
private struct LevelBar: View {
    var title: String
    var level: Float
    var tint: Color

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(verbatim: title).ataCaption().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(tint)
                            .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
                    }
                }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The first step's picture: the menu bar, then a recording that turns into a
/// transcript. Shapes only, so it reads the same in every language. Holds
/// still for Reduce Motion and for the snapshot renderer.
private struct WelcomeMock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsTranscript = false
    private let flip = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            MenuBarCallout()
            ZStack {
                recording.opacity(showsTranscript ? 0 : 1)
                transcript.opacity(showsTranscript ? 1 : 0)
            }
            .frame(height: 96)
        }
        .accessibilityHidden(true)
        .onReceive(flip) { _ in
            guard !reduceMotion, !Snapshots.rendering else { return }
            withAnimation(.easeInOut(duration: 0.6)) { showsTranscript.toggle() }
        }
    }

    private var recording: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Circle().fill(Theme.recordingSolid).frame(width: 8, height: 8)
                    line(width: 90, tint: Color.primary.opacity(0.25))
                    Spacer()
                    line(width: 40, tint: Color.primary.opacity(0.15))
                }
                bar(Theme.me, 0.7)
                bar(Theme.others, 0.45)
            }
        }
    }

    private var transcript: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                speaker(Theme.me, widths: [220, 140])
                speaker(Theme.others, widths: [260])
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func speaker(_ tint: Color, widths: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Circle().fill(tint).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(widths.indices, id: \.self) { line(width: widths[$0], tint: Color.primary.opacity(0.18)) }
            }
        }
    }

    private func line(width: CGFloat, tint: Color) -> some View {
        Capsule().fill(tint).frame(width: width, height: 6)
    }

    private func bar(_ tint: Color, _ fraction: CGFloat) -> some View {
        Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(tint).frame(width: proxy.size.width * fraction)
                }
            }
    }
}

/// A 24 pt menu-bar strip. The waveform is the symbol `MenuIcon` draws, called out
/// so the last step points at the real menu bar instead of listing it.
private struct MenuBarCallout: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Spacer(minLength: 0)
                Image(systemName: "wifi")
                    .foregroundStyle(.tertiary)
                Image(systemName: "battery.100")
                    .foregroundStyle(.tertiary)
                Image(systemName: MenuIcon.Symbol.waveform.systemName)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Theme.accent.opacity(0.16))
                    )
            }
            .ataHeadline()
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            Image(systemName: "arrow.up")
                .ataCaption()
                .foregroundStyle(Theme.accent)
                .padding(.trailing, Theme.Space.m)
        }
        .accessibilityHidden(true)
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

    /// Again after a result, for someone who unmuted or started some sound.
    func start(_ store: AppStore) {
        guard phase != .running else { return }
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
        let heard = TrialResult(peakMic: peakMic, peakMac: peakMac)
        phase = .finished(heardMic: heard.heardMic, heardMac: heard.heardMac)
    }
}
