import AVFoundation
import SwiftUI
import UIKit
import UserNotifications

/// First launch, in three steps: what Ata does, the microphone and
/// notifications, then your name and the language of your meetings.
/// A later recording with the microphone denied opens on the second step.
struct PhoneOnboarding: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, you
    }

    /// Where this presentation opened. A return visit for the microphone
    /// starts on permissions and closes there once the person is already set up.
    private let openedAt: Step

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.shareUsage) private var shareUsage = true
    @State private var step: Step
    /// Which way the next change slides. Set before `step`, so the step that
    /// leaves and the one that arrives move as one gesture.
    @State private var forward = true
    @State private var mic = AVAudioApplication.shared.recordPermission
    @State private var notifications = UNAuthorizationStatus.notDetermined

    init(start: Step = .welcome) {
        openedAt = start
        _step = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
            // One step at a time. The others are not built, so VoiceOver and
            // the UI tests cannot land on a step that is off screen.
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading),
                        removal: .move(edge: forward ? .leading : .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .presentationSizing(.page)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings is how a denied microphone becomes granted.
            if phase == .active { Task { await refresh() } }
        }
    }

    private var header: some View {
        HStack {
            // A hidden copy on the welcome step keeps the dots from jumping
            // when Back appears, and the one on the right keeps them centred.
            backButton
                .opacity(step == .welcome ? 0 : 1)
                .accessibilityHidden(step == .welcome)
                .allowsHitTesting(step != .welcome)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule()
                        .fill(item == step ? Theme.meTint : Color.secondary.opacity(0.35))
                        .frame(width: item == step ? 18 : 7, height: 7)
                }
            }
            .accessibilityHidden(true)
            Spacer(minLength: 8)
            backButton
                .hidden()
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.28), value: step)
    }

    private var backButton: some View {
        Button { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) } label: {
            Label("Back", systemImage: "chevron.left")
        }
    }

    private func page(_ item: Step) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                pageContent(item)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer(item)
                .padding(24)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private func pageContent(_ item: Step) -> some View {
        switch item {
        case .welcome: welcome
        case .permissions: permissions
        case .you: you
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            AppGlyph(size: 72)
            Text("Record it. Ata writes it up.")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "lock.iphone",
                        title: L("Records with the screen locked"),
                        detail: L("A meeting, a lecture, a doctor's visit. Tap once and put the iPhone down."))
                Feature(symbol: "person.2.wave.2",
                        title: L("Knows who said what"),
                        detail: L("Ata tells the voices apart. Name a voice once and it is recognised next time."))
                Feature(symbol: "hand.raised",
                        title: L("Made on this iPhone"),
                        detail: L("Transcripts are written on the device. No account, and your recordings are not sent to a server."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Ask the people you record first. In many places it is the law.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Let Ata hear the room")
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                CheckRow(ok: mic == .granted, title: L("Microphone"),
                         detail: L("To record. Audio stays on this iPhone.")) {
                    // App Review rejects "Allow" before the system prompt (5.1.1(iv)):
                    // the choice is the system's, this button only leads to it.
                    Button(mic == .denied ? L("Open Settings") : L("Continue")) { requestMic() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("microphone-permission")
                }
                CheckRow(ok: notifications == .authorized || notifications == .provisional,
                         title: L("Notifications"), detail: L("When a transcript is ready."), optional: true) {
                    Button(L("Continue")) { requestNotifications() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("notifications-permission")
                        .disabled(notifications == .denied)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var you: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Two questions")
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Your name")
                    .font(.subheadline.weight(.semibold))
                TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
                    .textContentType(.givenName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("onboarding-name")
                Text("Your lines are marked with this name. Ata also tells the other people in the room apart, and you name each voice once in People.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Picker("Language of your meetings", selection: $language) {
                    Text("Automatic").tag("auto")
                    ForEach(Pref.languageChoices, id: \.code) { choice in
                        Text(choice.name).tag(choice.code)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("onboarding-language")
                Text("Automatic chooses among your iPhone's languages. Pick one if your meetings are in another.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Share anonymous usage stats", isOn: $shareUsage)
                    .font(.subheadline.weight(.semibold))
                Text("Once a day: the app version, your country and how many minutes you recorded. Never your audio, transcripts or names.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func footer(_ item: Step) -> some View {
        VStack(spacing: 12) {
            if item == .you {
                Text(L("%d meetings a month are free. Ata Pro removes the limit.", FreeQuota.limit))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch item {
            case .welcome:
                bottomButton(L("Continue"), prominent: true, identifier: "onboarding-next") {
                    go(to: .permissions)
                }
            case .permissions:
                // Without the microphone, Continue is the one thing to press; a second
                // filled button saying "Not now" would compete with it.
                // A grant does not move the step on, even when notifications were
                // already answered: the person presses Next.
                bottomButton(mic == .granted ? L("Next") : L("Not now"),
                             prominent: mic == .granted,
                             identifier: "onboarding-next") {
                    leavePermissions()
                }
            case .you:
                bottomButton(L("Start using Ata"), prominent: true, identifier: "onboarding-finish") {
                    Pref.d.set(true, forKey: Pref.onboarded)
                    dismiss()
                }
            }
        }
    }

    private func bottomButton(_ title: String, prominent: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
        .modifier(FinishStyle(primary: prominent))
        .controlSize(.large)
        .accessibilityIdentifier(identifier)
    }

    private struct FinishStyle: ViewModifier {
        let primary: Bool

        func body(content: Content) -> some View {
            if primary {
                content.buttonStyle(.borderedProminent)
            } else {
                content.buttonStyle(.bordered)
            }
        }
    }

    private func go(to next: Step) {
        forward = next.rawValue > step.rawValue
        withAnimation(.easeInOut(duration: 0.28)) { step = next }
    }

    private func leavePermissions() {
        // Already finished setup and came back because recording was refused.
        if openedAt == .permissions && Pref.d.bool(forKey: Pref.onboarded) {
            dismiss()
            return
        }
        go(to: .you)
    }

    private func requestMic() {
        if mic == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        Task {
            _ = await PhoneRecorder.requestPermission()
            await refresh()
        }
    }

    private func requestNotifications() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
    }

    private func refresh() async {
        mic = AVAudioApplication.shared.recordPermission
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
