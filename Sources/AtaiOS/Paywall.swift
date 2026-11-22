import SwiftUI
import UIKit

/// What the paywall was opened for, and the two prompts that are not the paywall
/// itself: the eighty-percent banner and the first-transcript sheet.
@MainActor
final class ProPromptCenter: ObservableObject {
    static let shared = ProPromptCenter()

    @Published var trigger: Funnel.Trigger = .settings
    @Published var highlighted: ProFeature?
    /// Yearly is the plan the paywall opens on. The monthly snapshot turns it off.
    var preferYearly = true
    @Published var showEightyBanner = false
    @Published var firstTranscript: FirstTranscriptInvite?
    private var pending: Task<Void, Never>?

    /// The banner, once this calendar month, once the free minutes cross 80%.
    /// A snapshot launch leaves the record screens as they were.
    func refreshEighty(used: Int, isPro: Bool) {
        guard !Snapshots.rendering else { return }
        if isPro {
            showEightyBanner = false
            return
        }
        if showEightyBanner { return }
        let month = ProPrompt.monthID(Date())
        let already = Pref.d.string(forKey: ProPrompt.eightyPercentMonthKey) == month
        guard ProPrompt.due(used: used, limit: FreeQuota.limitMinutes, isPro: false,
                            lastShown: lastModalDate(), count: modalCount(),
                            event: .eightyPercent(alreadyThisMonth: already)) == .eightyPercent else { return }
        showEightyBanner = true
        Pref.d.set(month, forKey: ProPrompt.eightyPercentMonthKey)
    }

    /// Two seconds after a transcript finishes in the foreground, and never
    /// while a recording is going. The check runs again when the wait ends.
    func noteTranscript(_ meetingID: String) {
        guard !Snapshots.rendering, pending == nil, firstTranscript == nil else { return }
        guard decision(.firstTranscript(foreground: inForeground, recording: PhoneStore.shared.isRecording,
                                        celebrated: celebrated, reviewPromptToday: reviewAskedToday()))
                == .firstTranscript else { return }
        pending = Task { @MainActor in
            defer { self.pending = nil }
            try? await Task.sleep(for: .seconds(ProPrompt.firstTranscriptDelay))
            guard !Task.isCancelled else { return }
            guard self.decision(.firstTranscript(foreground: self.inForeground,
                                                 recording: PhoneStore.shared.isRecording,
                                                 celebrated: self.celebrated,
                                                 reviewPromptToday: self.reviewAskedToday()))
                    == .firstTranscript else { return }
            self.recordModal()
            Pref.d.set(true, forKey: Pref.firstTranscriptCelebrated)
            self.firstTranscript = FirstTranscriptInvite(id: meetingID)
        }
    }

    func openPaywall(_ trigger: Funnel.Trigger, feature: ProFeature? = nil) {
        self.trigger = trigger
        highlighted = feature
        preferYearly = true
        Funnel.count(.paywallShown(trigger))
        if trigger == .feature, let feature {
            Funnel.count(.featureLocked(feature))
        }
        if trigger == .limit {
            Funnel.count(.limitHit)
        }
        PhoneNavigation.shared.showPaywall()
    }

    private func decision(_ event: ProPrompt.Event) -> ProPrompt? {
        ProPrompt.due(used: PhoneStore.shared.freeUsed, limit: FreeQuota.limitMinutes,
                      isPro: ProAccess.shared.isPro, lastShown: lastModalDate(), count: modalCount(),
                      event: event)
    }

    private var inForeground: Bool { UIApplication.shared.applicationState == .active }
    private var celebrated: Bool { Pref.d.bool(forKey: Pref.firstTranscriptCelebrated) }

    private func reviewAskedToday() -> Bool {
        Pref.d.string(forKey: ProPrompt.reviewPromptDayKey) == ProPrompt.dayID(Date())
    }

    private func modalCount() -> Int { Pref.d.integer(forKey: Pref.proPromptCount) }

    private func lastModalDate() -> Date? {
        guard Pref.d.object(forKey: Pref.proPromptLastShown) != nil else { return nil }
        let value = Pref.d.double(forKey: Pref.proPromptLastShown)
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    private func recordModal() {
        Pref.d.set(Date().timeIntervalSince1970, forKey: Pref.proPromptLastShown)
        Pref.d.set(modalCount() + 1, forKey: Pref.proPromptCount)
    }
}

struct FirstTranscriptInvite: Identifiable, Equatable {
    var id: String
}

/// Ata Pro: the two plans, the trial when the yearly offer is still open, and
/// Restore plus the two links the App Store asks for. The close control stays
/// on screen. Shown when the free minutes run out, from Settings, and from a
/// locked feature.
struct Paywall: View {
    @EnvironmentObject var store: PhoneStore
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var prompts = ProPromptCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var yearlySelected = ProPromptCenter.shared.preferYearly

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://mcpeixoto.github.io/Ata/privacy/")!

    /// Apple's minimum hit target. The glyph inside it is smaller.
    private static let closeTarget: CGFloat = 44

    /// Track 10 inserts a feature here in the change that ships it. Until then
    /// the paywall does not advertise it. Opening the paywall from that lock
    /// still puts the one line first.
    private static let shipped: Set<ProFeature> = []

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.l) {
                AppGlyph(size: 64)
                VStack(spacing: Theme.Space.s) {
                    Text("Ata Pro")
                        .ataLargeTitle()
                    Text("Every meeting, written up.")
                        .ataBody()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                quota

                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(benefits, id: \.id) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Image(systemName: "checkmark")
                                .ataFont(13, weight: .semibold)
                                .foregroundStyle(Theme.accent)
                            Text(verbatim: line.title)
                                .ataBody()
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !pro.isPro {
                    plans
                    purchase
                }

                if let message = pro.message {
                    Text(message)
                        .ataCaption()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Theme.Space.s) {
                    Button("Restore") { Task { await pro.restore() } }
                        .buttonStyle(.plain)
                        .disabled(pro.purchasing)
                        .accessibilityIdentifier("restore")
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Link("Terms", destination: Self.termsURL)
                        .accessibilityIdentifier("terms")
                    Text(verbatim: "·").foregroundStyle(.secondary)
                    Link("Privacy", destination: Self.privacyURL)
                        .accessibilityIdentifier("privacy")
                }
                .ataCaption()
            }
            .padding(Theme.Space.xl)
            .padding(.top, Self.closeTarget)
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .ataFont(13, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.closeTarget, height: Self.closeTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Close"))
            .accessibilityIdentifier("close")
            .padding(.trailing, Theme.Space.s)
        }
        .onAppear { yearlySelected = prompts.preferYearly }
        .task {
            if pro.monthly == nil, pro.yearly == nil { await pro.load() }
        }
        .onChange(of: pro.isPro) { _, isPro in
            if isPro { dismiss() }
        }
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let context {
                Text(verbatim: context)
                    .ataBody()
                    .fixedSize(horizontal: false, vertical: true)
            }
            QuotaMeter(usedMinutes: store.freeUsed, limitMinutes: FreeQuota.limitMinutes)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var context: String? {
        switch prompts.trigger {
        case .limit:
            return L("This month's free minutes are used.")
        case .eightyPercent:
            let left = FreeQuota.remaining(used: store.freeUsed)
            return left == 1 ? L("1 free minute left this month") : L("%d free minutes left this month", left)
        case .firstTranscript:
            return L("Your first meeting is written up")
        case .onboarding, .settings, .feature, .recordHome:
            return nil
        }
    }

    private var benefits: [(id: String, title: String)] {
        var lines: [(id: String, title: String)] = []
        func add(_ feature: ProFeature) {
            guard let title = Self.title(of: feature) else { return }
            lines.append((feature.rawValue, title))
        }
        if let highlighted = prompts.highlighted { add(highlighted) }
        lines.append(("minutes", L("Unlimited minutes")))
        for feature in ProFeature.allCases where Self.shipped.contains(feature) && feature != prompts.highlighted {
            add(feature)
        }
        lines.append(("mac", L("Unlocks your Mac too")))
        lines.append(("private", L("Private: stays on device")))
        return lines
    }

    private static func title(of feature: ProFeature) -> String? {
        switch feature {
        case .askMeetings: return L("Ask all your meetings")
        case .customTemplates: return L("Your own summary formats")
        case .documentExport: return L("Export a meeting as a document")
        }
    }

    private var plans: some View {
        VStack(spacing: Theme.Space.s) {
            PlanCard(title: L("Yearly"), price: yearlyPrice, detail: yearlyDetail,
                     badge: pro.savingsPercent.map { L("SAVE %d %%", $0) },
                     selected: yearlySelected) { yearlySelected = true }
                .accessibilityIdentifier("plan-yearly")
            PlanCard(title: L("Monthly"), price: monthlyPrice, detail: "",
                     badge: nil, selected: !yearlySelected) { yearlySelected = false }
                .accessibilityIdentifier("plan-monthly")
        }
    }

    private var yearlyPrice: String {
        guard let amount = pro.amount(for: .yearly) else { return L("Unavailable right now") }
        let head = L("%@ / %@", amount, pro.periodName(for: .yearly))
        guard let perMonth = pro.yearlyPerMonthAmount() else { return head }
        return [head, L("%@ / %@", perMonth, L("month"))].joined(separator: " · ")
    }

    private var yearlyDetail: String {
        guard pro.trialEligible, pro.introductoryDays > 0 else { return "" }
        return L("%d days free", pro.introductoryDays)
    }

    private var monthlyPrice: String {
        guard let amount = pro.amount(for: .monthly) else { return L("Unavailable right now") }
        return L("%@ / %@", amount, pro.periodName(for: .monthly))
    }

    @ViewBuilder
    private var purchase: some View {
        let plan: Plan = yearlySelected ? .yearly : .monthly
        let ready = pro.product(for: plan) != nil || (Snapshots.rendering && pro.amount(for: plan) != nil)
        VStack(spacing: Theme.Space.s) {
            Button {
                guard let product = pro.product(for: plan) else { return }
                Task { await pro.purchase(product) }
            } label: {
                Group {
                    if pro.purchasing || (pro.loading && pro.amount(for: plan) == nil) {
                        ProgressView().tint(Theme.accentInk)
                    } else {
                        Text(verbatim: subscribeLabel)
                            .ataHeadline()
                    }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!ready || pro.purchasing)
            .accessibilityIdentifier("subscribe")

            if pro.unavailable && !pro.loading {
                Button("Try again") { Task { await pro.load() } }
                    .ataBody()
            }

            if let timeline {
                Text(verbatim: timeline)
                    .ataCaption()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("trial-timeline")
            }

            if let renewal {
                Text(verbatim: renewal)
                    .ataCaption()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("renewal")
            }
        }
    }

    private var subscribeLabel: String {
        if yearlySelected, pro.trialEligible, pro.introductoryDays > 0 {
            return L("Try %d days free", pro.introductoryDays)
        }
        return L("Subscribe")
    }

    private var timeline: String? {
        guard yearlySelected, pro.trialEligible, pro.introductoryDays > 2,
              let amount = pro.amount(for: .yearly) else { return nil }
        let days = pro.introductoryDays
        return L("Today: full access · Day %d: reminder · Day %d: %@",
                 PlanMath.reminderDay(trialDays: days), days, amount)
    }

    private var renewal: String? {
        let plan: Plan = yearlySelected ? .yearly : .monthly
        guard let amount = pro.amount(for: plan) else { return nil }
        return L("Then %@/%@. Cancel anytime in Settings.", amount, pro.periodName(for: plan))
    }
}

/// Once, after the first transcript. Open the meeting, or look at Pro.
struct FirstTranscriptPrompt: View {
    var meetingID: String
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var prompts = ProPromptCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Text("Your first meeting is written up")
                .ataLargeTitle()
                .multilineTextAlignment(.center)
            Button {
                let id = meetingID
                dismiss()
                PhoneNavigation.shared.showMeeting(id)
            } label: {
                Text("Open meeting")
                    .ataHeadline()
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("open-meeting")

            Button { prompts.openPaywall(.firstTranscript) } label: {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Ata Pro")
                        .ataHeadline()
                    Text("Every meeting, written up.")
                        .ataCaption()
                        .foregroundStyle(.secondary)
                    if let amount = pro.amount(for: .yearly) {
                        Text(verbatim: L("%@ / %@", amount, pro.periodName(for: .yearly)))
                            .ataBody()
                    }
                }
                .padding(Theme.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
