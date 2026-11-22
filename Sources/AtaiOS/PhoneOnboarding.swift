import AVFoundation
import StoreKit
import SwiftUI
import UIKit
import UserNotifications

/// First launch, in six steps. The step is remembered, so leaving and coming
/// back continues there. A later recording with the microphone denied opens
/// on the permissions step and closes there once the person is already set up.
struct PhoneOnboarding: View {
    typealias Step = OnboardingFlow.Step

    /// Where this presentation opened. A return visit for the microphone
    /// starts on permissions and closes there once the person is already set up.
    private let openedAt: Step

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var pro = ProStore.shared
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(Pref.language) private var language = "auto"
    @AppStorage(Pref.shareUsage) private var shareUsage = true
    @StateObject private var trial = OnboardingTrial()
    @State private var step: Step
    /// Which way the next change slides. Set before `step`, so the step that
    /// leaves and the one that arrives move as one gesture.
    @State private var forward = true
    @State private var mic = AVAudioApplication.shared.recordPermission
    @State private var notifications = UNAuthorizationStatus.notDetermined

    init(start: Step = .welcome) {
        openedAt = start
        _step = State(initialValue: Self.opening(start))
    }

    /// Permissions re-entry stays on permissions. A screenshot launch shows the
    /// step it asked for. Anyone else continues from the furthest step reached.
    private static func opening(_ start: Step) -> Step {
        if Snapshots.rendering || start == .permissions { return start }
        guard let raw = Pref.d.object(forKey: Pref.onboardingStep) as? Int,
              let saved = Step(rawValue: raw) else { return start }
        return saved.rawValue >= start.rawValue ? saved : start
    }

    /// The flow test pretends the microphone is granted so it can walk the
    /// try-it step without the system prompt. A real launch uses the system.
    private var micGranted: Bool {
        if Snapshots.rendering, ProcessInfo.processInfo.arguments.contains("-AtaOnboardingMicGranted") {
            return true
        }
        return mic == .granted
    }

    /// The yearly plan, once it has loaded. A screenshot of the last step
    /// shows a stand-in: StoreKit does not answer a UI-test launch.
    private var proPlan: OnboardingProPlan? {
        if Snapshots.rendering, Snapshots.screen == .onboardingPro { return .snapshot }
        guard let product = OnboardingYearly.product else { return nil }
        return OnboardingYearly.plan(for: product)
    }

    var body: some View {
        OnboardingScaffold(
            step: step.rawValue,
            count: Step.allCases.count,
            back: step == .welcome ? nil : { goBack() }
        ) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading),
                        removal: .move(edge: forward ? .leading : .trailing)))
            }
            .animation(.easeInOut(duration: 0.28), value: step)
        } footer: {
            stepFooter
        }
        .background(Color(.systemBackground))
        .interactiveDismissDisabled()
        .presentationSizing(.page)
        .task { await refresh() }
        .task {
            guard !Snapshots.rendering, pro.product == nil else { return }
            await pro.load()
        }
        .onAppear { note(step) }
        .onChange(of: step) { _, new in note(new) }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings is how a denied microphone becomes granted.
            if phase == .active { Task { await refresh() } }
        }
        .onChange(of: pro.isPro) { _, isPro in
            if isPro { finish() }
        }
    }

    @ViewBuilder
    private func page(_ item: Step) -> some View {
        switch item {
        case .welcome: welcome
        case .useCase: useCase
        case .permissions: permissions
        case .you: you
        case .tryIt: tryIt
        case .pro: proStep
        }
    }

    private var welcome: some View {
        VStack(spacing: Theme.Space.xl) {
            WelcomeStory()
            Text("Record it. Ata writes it up.")
                .font(.largeTitle.bold()) // 34 pt bold; ataLargeTitle is 20 pt
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.l) {
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
                .ataBody()
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var useCase: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("What will you record most?")
                .font(.title.bold()) // 28 pt bold; ataLargeTitle is 20 pt
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.Space.s) {
                ForEach(UseCase.allCases, id: \.self) { item in
                    Button { choose(item) } label: {
                        Card {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: item.symbol)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 28) // icon column, not a Space step
                                    .accessibilityHidden(true)
                                Text(verbatim: useCaseTitle(item))
                                    .font(.headline) // 17 pt semibold; ataHeadline is 13 pt
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding-usecase-\(item.rawValue)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            Text("Let Ata hear the room")
                .font(.title.bold()) // 28 pt bold; ataLargeTitle is 20 pt
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: Theme.Space.m) {
                PermissionCard(ok: micGranted, title: L("Microphone"),
                               detail: L("To record. Audio stays on this iPhone.")) {
                    // App Review rejects "Allow" before the system prompt (5.1.1(iv)):
                    // the choice is the system's, this button only leads to it.
                    Button(mic == .denied ? L("Open Settings") : L("Continue")) { requestMic() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("microphone-permission")
                }
                PermissionCard(ok: notifications == .authorized || notifications == .provisional,
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
        VStack(alignment: .leading, spacing: 22) { // 22 pt; 2 pt under Space.xl
            Text("Two questions")
                .font(.title.bold()) // 28 pt bold; ataLargeTitle is 20 pt
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) { // 6 pt; 2 pt from Space.xs and Space.s
                Text("Your name")
                    .ataFont(15, weight: .semibold) // 15 pt semibold; ataTitle is bold rounded
                TextField("Your name in the transcript", text: $myName, prompt: Text("Me"))
                    .textContentType(.givenName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("onboarding-name")
                Text("Your lines are marked with this name. Ata also tells the other people in the room apart, and you name each voice once in People.")
                    .ataBody()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) { // 6 pt; 2 pt from Space.xs and Space.s
                // A menu picker draws only its value: the question is written out.
                languageQuestion
                Text("Automatic chooses among your iPhone's languages. Pick one if your meetings are in another.")
                    .ataBody()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Toggle(isOn: $shareUsage) {
                    Text("Share anonymous usage stats")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .ataFont(15, weight: .semibold) // 15 pt semibold; ataTitle is bold rounded
                Text("Once a day: the app version, your country and how many minutes you recorded. Never your audio, transcripts or names.")
                    .ataBody()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// At the largest sizes the picker drops under the question instead of clipping it.
    private var languageQuestion: some View {
        let label = Text("Language of your meetings")
            .ataFont(15, weight: .semibold) // 15 pt semibold; ataTitle is bold rounded
            .fixedSize(horizontal: false, vertical: true)
        let picker = Picker("Language of your meetings", selection: $language) {
            Text("Automatic").tag("auto")
            ForEach(Pref.languageChoices, id: \.code) { choice in
                Text(choice.name).tag(choice.code)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("onboarding-language")
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    label
                    picker.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack {
                    label
                    Spacer(minLength: Theme.Space.s)
                    picker
                }
            }
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("Try it: say a sentence")
                .font(.title.bold()) // 28 pt bold; ataLargeTitle is 20 pt
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(trial.phase == .recording ? Theme.recordingSolid : Theme.accent)
                    .frame(width: 8, height: 8) // status dot, thinner than Radius.small
                    .accessibilityHidden(true)
                Text(verbatim: clock(trial.seconds))
                    .font(.headline.monospacedDigit()) // 17 pt semibold digits; no ata style is monospaced
            }
            .frame(maxWidth: .infinity)
            LevelMeter(level: trial.level, tint: Theme.recordingSolid)
            Text(verbatim: trial.transcript.isEmpty ? L("…your words appear here") : trial.transcript)
                .ataBody()
                .foregroundStyle(trial.transcript.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if trial.heard {
                Label("Ata heard you", systemImage: "checkmark.circle.fill")
                    .ataHeadline()
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { trial.begin(language: language) }
    }

    private var proStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("You're set")
                .font(.title.bold()) // 28 pt bold; ataLargeTitle is 20 pt
                .fixedSize(horizontal: false, vertical: true)
            Text(L("%d minutes a month are free. Ata Pro removes the limit.", FreeQuota.limitMinutes))
                .ataCallout()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let plan = proPlan {
                PlanCard(title: plan.title, price: plan.price, detail: plan.detail,
                         badge: plan.badge, selected: true) { buy() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stepFooter: some View {
        switch step {
        case .welcome:
            bottomButton(L("Continue"), prominent: true, identifier: "onboarding-next") { advance() }
        case .useCase:
            EmptyView()
        case .permissions:
            // Without the microphone, Continue is the one thing to press; a second
            // filled button saying "Not now" would compete with it.
            // A grant does not move the step on, even when notifications were
            // already answered: the person presses Next.
            bottomButton(micGranted ? L("Next") : L("Not now"),
                         prominent: micGranted,
                         identifier: "onboarding-next") {
                leavePermissions()
            }
        case .you:
            bottomButton(L("Continue"), prominent: true, identifier: "onboarding-next") { advance() }
        case .tryIt:
            // Side by side until the two titles no longer fit, then stacked.
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: Theme.Space.s) { tryContinue; trySkip }
                } else {
                    HStack(spacing: Theme.Space.s) { tryContinue; trySkip }
                }
            }
        case .pro:
            if let plan = proPlan {
                VStack(spacing: Theme.Space.s) {
                    Button { buy() } label: {
                        Text(verbatim: plan.offersTrial
                             ? L("Try 7 days free")
                             : L("Subscribe for %@", plan.price))
                            .font(.headline) // 17 pt semibold; ataHeadline is 13 pt
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(pro.purchasing)
                    .accessibilityIdentifier("onboarding-trial")
                    Button { finish() } label: {
                        Text("Continue free")
                            .font(.headline) // 17 pt semibold; ataHeadline is 13 pt
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("onboarding-finish")
                }
            } else {
                bottomButton(L("Start using Ata"), prominent: true, identifier: "onboarding-finish") {
                    finish()
                }
            }
        }
    }

    private var tryContinue: some View {
        Button {
            if trial.confirm(language: language) { advance() }
        } label: {
            Text(L("Continue"))
                .font(.headline) // 17 pt semibold; ataHeadline is 13 pt
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("onboarding-next")
    }

    private var trySkip: some View {
        Button {
            trial.abandon()
            advance()
        } label: {
            Text("Skip")
                .font(.headline) // 17 pt semibold; ataHeadline is 13 pt
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityIdentifier("onboarding-skip")
    }

    private func bottomButton(_ title: String, prominent: Bool, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.headline) // 17 pt semibold; ataHeadline is 13 pt
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(FinishStyle(primary: prominent))
        .accessibilityIdentifier(identifier)
    }

    private struct FinishStyle: ViewModifier {
        let primary: Bool

        func body(content: Content) -> some View {
            if primary {
                content.buttonStyle(PrimaryButtonStyle())
            } else {
                content.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func useCaseTitle(_ useCase: UseCase) -> String {
        switch useCase {
        case .work: return L("Work meetings")
        case .classes: return L("Classes")
        case .interviews: return L("Interviews")
        case .personal: return L("Personal")
        }
    }

    private func choose(_ useCase: UseCase) {
        // A screenshot launch must not write the simulator's defaults: the
        // settings shot is taken in the same simulator afterwards.
        if !Snapshots.rendering {
            let choice = useCase.defaults
            Pref.d.set(useCase.rawValue, forKey: Pref.useCase)
            Pref.d.set(choice.category, forKey: Pref.defaultCategory)
            if let mode = choice.mode, let parsed = RecordingMode(rawValue: mode) {
                PhoneStore.shared.mode = parsed
            }
        }
        advance()
    }

    private func note(_ step: Step) {
        guard !Snapshots.rendering else { return }
        let stored = (Pref.d.object(forKey: Pref.onboardingStep) as? Int) ?? -1
        if step.rawValue > stored {
            Pref.d.set(step.rawValue, forKey: Pref.onboardingStep)
        }
        Funnel.count(.onboardingStep(step.rawValue))
    }

    private func go(to next: Step) {
        forward = next.rawValue > step.rawValue
        withAnimation(.easeInOut(duration: 0.28)) { step = next }
    }

    private func goBack() {
        guard let previous = OnboardingFlow.previous(from: step, micGranted: micGranted) else { return }
        go(to: previous)
    }

    private func advance() {
        guard let next = OnboardingFlow.next(from: step, micGranted: micGranted, productLoaded: proPlan != nil) else {
            finish()
            return
        }
        go(to: next)
    }

    private func leavePermissions() {
        // Already finished setup and came back because recording was refused.
        if openedAt == .permissions && Pref.d.bool(forKey: Pref.onboarded) {
            dismiss()
            return
        }
        advance()
    }

    private func finish() {
        trial.abandon()
        if !Snapshots.rendering {
            Pref.d.set(true, forKey: Pref.onboarded)
        }
        dismiss()
    }

    private func buy() {
        Task {
            await OnboardingYearly.purchase()
            if pro.isPro { finish() }
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(seconds, 0) / 60, max(seconds, 0) % 60)
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

/// The yearly subscription, when ProStore has one. The monthly product is not
/// offered here. Until the yearly product loads this stays empty and the
/// last step only offers the free minutes.
@MainActor
enum OnboardingYearly {
    static var product: Product? {
        guard let product = ProStore.shared.yearly, isYearly(product) else { return nil }
        return product
    }

    static func isYearly(_ product: Product) -> Bool {
        product.subscription?.subscriptionPeriod.unit == .year
    }

    static func plan(for product: Product) -> OnboardingProPlan {
        let trial = ProStore.shared.trialEligible && product.subscription?.introductoryOffer?.paymentMode == .freeTrial
        return OnboardingProPlan(
            title: product.displayName,
            price: product.displayPrice,
            detail: L("Unlimited meetings, including your Mac"),
            badge: trial ? L("7 days free") : nil,
            offersTrial: trial)
    }

    /// Buys the yearly product only,
    /// so a monthly product can never be sold from this step.
    static func purchase() async {
        guard let product else { return }
        await ProStore.shared.purchase(product)
    }
}

/// What the last step's card shows. Built from StoreKit, or from `snapshot`
/// when the screenshot run cannot ask the App Store.
struct OnboardingProPlan: Equatable {
    var title: String
    var price: String
    var detail: String
    var badge: String?
    var offersTrial: Bool

    static var snapshot: OnboardingProPlan {
        OnboardingProPlan(
            title: L("Ata Pro"),
            price: L("%@ / %@", "€44.99", L("year")),
            detail: L("Unlimited meetings, including your Mac"),
            badge: L("7 days free"),
            offersTrial: true)
    }
}

/// Ten seconds into a temporary WAV, then thrown away. Never a meeting, so it
/// never joins the library and never counts toward the free minutes.
@MainActor
final class OnboardingTrial: ObservableObject {
    enum Phase: Equatable { case idle, recording, done }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var level: Float = 0
    @Published private(set) var seconds = 0
    @Published private(set) var heard = false
    @Published private(set) var transcript = ""

    private let recorder = PhoneRecorder()
    private var clip: URL?
    private var peak: Float = 0
    private var sample: Task<Void, Never>?
    private var transcribe: Task<Void, Never>?

    func begin(language: String) {
        guard phase == .idle, sample == nil else { return }
        if Snapshots.rendering {
            // The last frame: a sentence already heard, so the shot and the
            // flow test do not open the microphone.
            level = 0.62
            seconds = 7
            heard = true
            phase = .done
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ata-onboarding-\(UUID().uuidString).wav")
        clip = url
        do {
            try recorder.startClip(at: url)
        } catch {
            deleteClip()
            return
        }
        phase = .recording
        let started = Date()
        sample = Task { await self.watch(started: started, language: language) }
    }

    /// Continue. Stops a recording in progress and stays, so the result can
    /// show; a second press, or a clip that never started, moves on.
    func confirm(language: String) -> Bool {
        if phase == .recording {
            judge(language: language)
            return false
        }
        abandon()
        return true
    }

    func abandon() {
        sample?.cancel()
        sample = nil
        transcribe?.cancel()
        transcribe = nil
        recorder.stopClip()
        deleteClip()
        if phase == .recording { phase = .done }
    }

    private func watch(started: Date, language: String) async {
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= 10 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
            noteLevel()
            seconds = min(10, Int(elapsed))
        }
        guard !Task.isCancelled else { return }
        seconds = 10
        judge(language: language)
    }

    private func noteLevel() {
        level = recorder.level
        peak = max(peak, level)
        heard = TrialResult(peakMic: peak, peakMac: 0).heardMic
    }

    private func judge(language: String) {
        guard phase == .recording else { return }
        noteLevel()
        phase = .done
        recorder.stopClip()
        let keep = heard && clip != nil
        if keep {
            transcribe = Task { await self.writeDown(language: language) }
        } else {
            deleteClip()
        }
        sample?.cancel()
    }

    /// Transcribes only a language whose model is already on the phone.
    /// Asking for one that is not would start a download during the try-out.
    private func writeDown(language: String) async {
        defer { deleteClip() }
        guard let clip, let code = await ready(language), !Task.isCancelled else { return }
        let segments = try? await AppleSpeechEngine.transcribe(
            audio: clip, speaker: Pref.myNameOrDefault, language: code,
            plausible: [code], progress: { _ in })
        let text = (segments ?? []).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, !Task.isCancelled { transcript = text }
    }

    private func ready(_ language: String) async -> String? {
        guard AppleSpeechEngine.isAvailable else { return nil }
        let codes = language == "auto" ? LanguageChoice.plausible : [language]
        for code in codes {
            guard let id = await AppleSpeechEngine.localeID(for: code) else { continue }
            if await AppleSpeechEngine.isInstalled(id) { return code }
        }
        return nil
    }

    private func deleteClip() {
        if let clip { try? FileManager.default.removeItem(at: clip) }
        clip = nil
    }
}

/// Three cards — waveform, transcript, summary — cross-fading. Each holds for
/// 3 seconds. Reduce Motion and screenshot runs stay on the summary, the last frame.
private struct WelcomeStory: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frame = 0

    private var animates: Bool { !reduceMotion && !Snapshots.rendering }
    private var index: Int { animates ? frame : 2 }

    /// Shared height so the crossfade does not jump. The bars need the room.
    private let cardHeight: CGFloat = 132

    var body: some View {
        ZStack {
            if animates || index == 0 { waveform.opacity(index == 0 ? 1 : 0) }
            if animates || index == 1 { transcript.opacity(index == 1 ? 1 : 0) }
            if animates || index == 2 { summary.opacity(index == 2 ? 1 : 0) }
        }
        .frame(maxWidth: .infinity, minHeight: cardHeight)
        .accessibilityHidden(true)
        .task { await play() }
    }

    private func play() async {
        guard animates else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.45)) { frame = (frame + 1) % 3 }
        }
    }

    /// Gaps stay under Space.xs so twenty bars read as one waveform, not a row of pills.
    private var waveform: some View {
        Card {
            HStack(alignment: .center, spacing: 3) { // 3 pt; Space.xs (4) would split the bars apart
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(Theme.recordingSolid)
                        .frame(width: 4, height: height)
                }
            }
            .frame(maxWidth: .infinity, minHeight: cardHeight - Theme.Space.xl)
        }
    }

    private var transcript: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(L("Alex: Let's ship it on Friday."))
                    .ataBody()
                Text(L("Sam: I'll send the notes."))
                    .ataBody()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: cardHeight - Theme.Space.xl, alignment: .leading)
        }
    }

    private var summary: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                line(L("Ship on Friday"))
                line(L("Notes go out today"))
                line(L("Recorded on this iPhone"))
            }
            .frame(maxWidth: .infinity, minHeight: cardHeight - Theme.Space.xl, alignment: .leading)
        }
    }

    private func line(_ text: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "checkmark")
                .foregroundStyle(Theme.accent)
            Text(verbatim: text)
                .ataBody()
        }
    }

    private static let bars: [CGFloat] = [
        14, 28, 18, 44, 32, 64, 40, 72, 48, 80,
        36, 68, 24, 52, 18, 40, 22, 48, 16, 30,
    ]
}

/// One permission on the permissions step. Granted replaces the symbol with a
/// check and hides the button. At the largest text sizes the button moves
/// under the title so nothing is clipped.
private struct PermissionCard<Trailing: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    var optional = false
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var tint: Color {
        if ok { return .green } // no success colour in Theme; system green is the granted state
        return optional ? Color.secondary : Theme.warning
    }

    private var symbol: String {
        if ok { return "checkmark" }
        return optional ? "bell" : "exclamationmark"
    }

    private var circleFill: Color {
        if ok { return Color.green.opacity(0.15) } // same granted green as the glyph
        if optional { return Color.secondary.opacity(0.12) }
        return Theme.warning.opacity(0.15)
    }

    var body: some View {
        Card(padding: Theme.Space.l) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        summary
                        if !ok {
                            trailing.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        summary
                        if !ok { trailing.fixedSize() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.2), value: ok)
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.body.weight(.bold)) // 17 pt bold; ataTitle is 15 pt rounded
                .foregroundStyle(tint)
                .padding(Theme.Space.m)
                .background(Circle().fill(circleFill))
                .accessibilityLabel(L("Granted"))
                .accessibilityHidden(!ok)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(.headline) // 17 pt semibold; ataHeadline is 13 pt
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .ataFont(15) // 15 pt; ataTitle is bold rounded
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
