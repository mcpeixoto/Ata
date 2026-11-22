import SwiftUI

/// The Record tab at rest, top to bottom: greeting and this week, banners, the
/// record button and mode, what is being transcribed, recent meetings, the free
/// minutes and one tip. 00:00 is not shown: nothing is being timed yet, and a
/// spare zero would sit on its own the way the free-meetings line used to.
struct RecordHomeIdle: View {
    @EnvironmentObject var store: PhoneStore
    @ObservedObject private var access = ProAccess.shared
    @AppStorage(Pref.myName) private var myName = ""
    @AppStorage(RecordHomeModel.bannerDismissedMonthKey) private var bannerMonth = ""
    @AppStorage(RecordHomeModel.dismissedTipsKey) private var dismissedTips = ""

    private var navigation: PhoneNavigation { .shared }

    var body: some View {
        let now = Date()
        let library = store.meetings.filter { $0.status != .recording }
        let cards = RecordHomeModel.cards(
            libraryIsEmpty: library.isEmpty,
            transcribing: transcribingMeeting != nil,
            isPro: access.isPro,
            usedMinutes: store.freeUsed,
            limitMinutes: FreeQuota.limitMinutes,
            bannerDismissedThisMonth: RecordHomeModel.dismissedThisMonth(stored: bannerMonth, now: now),
            tip: RecordHomeModel.tip(day: RecordHomeModel.dayIndex(now),
                                     dismissed: RecordHomeModel.decodeTips(dismissedTips)))

        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header(library: library, now: now)
                banners(cards)
                hero
                if cards.transcribing, let meeting = transcribingMeeting {
                    transcribingCard(meeting)
                }
                if cards.recents {
                    recents(Array(library.prefix(RecordHomeModel.recentCount)))
                }
                if cards.firstRun { firstRun }
                if cards.quotaMeter { quotaCard }
                if let tip = cards.tip { tipBanner(tip) }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Header

    private func header(library: [Meeting], now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(verbatim: greeting(now: now))
                .ataLargeTitle()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: summary(library: library, now: now))
                .ataCallout()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func greeting(now: Date) -> String {
        // The screenshots' status bar says 9:41, so they say good morning whatever the hour.
        let hour = Snapshots.rendering ? 9 : Calendar.current.component(.hour, from: now)
        let name = RecordHomeModel.greetingName(stored: myName, placeholder: L("Me"))
        switch (RecordHomeModel.greeting(hour: hour), name) {
        case (.morning, nil): return L("Good morning")
        case (.afternoon, nil): return L("Good afternoon")
        case (.evening, nil): return L("Good evening")
        case (.morning, let name?): return L("Good morning, %@", name)
        case (.afternoon, let name?): return L("Good afternoon, %@", name)
        case (.evening, let name?): return L("Good evening, %@", name)
        }
    }

    private func summary(library: [Meeting], now: Date) -> String {
        let week = RecordHomeModel.week(library.map { ($0.startedAt, $0.duration ?? 0) }, now: now)
        guard let week = RecordHomeModel.summary(libraryIsEmpty: library.isEmpty, week: week) else {
            return L("Ready when you are")
        }
        let length = Insights.duration(minutes: week.minutes)
        return week.meetings == 1
            ? L("1 meeting this week · %@", length)
            : L("%d meetings this week · %@", week.meetings, length)
    }

    // MARK: Banners

    @ViewBuilder
    private func banners(_ cards: RecordHomeModel.Cards) -> some View {
        if let error = store.lastError {
            Banner(kind: .danger, mark: .symbol("exclamationmark.triangle.fill"), title: Text(verbatim: error),
                   dismiss: { store.lastError = nil })
        }
        if let warning = store.warning {
            Banner(kind: .warning, mark: .symbol("exclamationmark.circle.fill"), title: Text(verbatim: warning))
        }
        if cards.quotaBanner {
            let left = FreeQuota.remaining(used: store.freeUsed)
            Banner(kind: .warning, mark: .symbol("hourglass"),
                   title: Text(verbatim: left == 1 ? L("1 free minute left this month")
                                                   : L("%d free minutes left this month", left)),
                   action: {
                       ProPromptCenter.shared.openPaywall(.eightyPercent)
                   },
                   showsChevron: true,
                   dismiss: { bannerMonth = RecordHomeModel.month(Date()) })
        }
    }

    // MARK: Record button

    private var hero: some View {
        let caption = RecordHomeModel.caption(isStarting: store.phase == .starting,
                                              isStopping: store.phase == .stopping,
                                              isRecording: store.isRecording)
        return VStack(spacing: Theme.Space.m) {
            HeroRecordButton(size: 132, state: caption == .starting ? .busy : .idle) { store.toggleRecording() }
                .disabled(store.phase == .starting)
                .accessibilityLabel(heroLabel(caption))
                .sensoryFeedback(.impact, trigger: store.isRecording)
                .padding(.vertical, Theme.Space.s)
            Group {
                switch caption {
                case .starting: Text("Starting…")
                case .saving: Text("Saving…")
                default: Text("Tap to record")
                }
            }
            .ataHeadline()
            .foregroundStyle(caption == .tapToRecord ? Color.primary : Color.secondary)
            .accessibilityHidden(true)
            modePicker
                .padding(.top, Theme.Space.s)
        }
        .frame(maxWidth: .infinity)
    }

    private func heroLabel(_ caption: RecordHomeModel.ButtonCaption) -> String {
        switch caption {
        case .starting: return L("Starting")
        case .saving: return L("Saving…")
        case .tapToRecord, .none: return L("Record")
        }
    }

    private var modePicker: some View {
        VStack(spacing: Theme.Space.s) {
            Picker("Mode", selection: $store.mode) {
                ForEach(RecordingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(store.mode == .inPerson
                 ? L("For a conversation in the room. Put the iPhone between you.")
                 : L("For a call on another phone or computer's speaker, with this iPhone next to it."))
                .ataBody()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Transcribing

    private var transcribingMeeting: Meeting? {
        guard let id = store.transcribingID else { return nil }
        return store.meetings.first { $0.id == id }
    }

    private func transcribingCard(_ meeting: Meeting) -> some View {
        Button { navigation.showMeeting(meeting.id) } label: {
            Card(padding: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(verbatim: store.transcribeStage?.label ?? L("Transcribing…"))
                            .ataHeadline()
                        Spacer(minLength: Theme.Space.s)
                        Text(store.transcribeProgress, format: .percent.precision(.fractionLength(0)))
                            .ataCallout()
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .ataFont(11, weight: .semibold) // 11 pt semibold; ataCaption is regular
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: meeting.title).lineLimit(1)
                        Text(verbatim: meeting.title).fixedSize(horizontal: false, vertical: true)
                    }
                    .ataCallout()
                    .foregroundStyle(.secondary)
                    ProgressView(value: min(max(store.transcribeProgress, 0), 1))
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("record-transcribing")
    }

    // MARK: Recent

    private func recents(_ meetings: [Meeting]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(L("Recent"))
                Spacer()
                Button(L("See all")) { navigation.tab = .meetings }
                    .ataCallout()
                    .tint(Theme.accent)
            }
            Card(padding: Theme.Space.m) {
                VStack(spacing: 0) { // flush rows; the dividers carry the gap
                    ForEach(Array(meetings.enumerated()), id: \.element.id) { index, meeting in
                        if index > 0 { Divider().padding(.vertical, Theme.Space.s) }
                        Button { navigation.showMeeting(meeting.id) } label: {
                            HStack {
                                MeetingRowContent(meeting: meeting) {
                                    ViewThatFits(in: .horizontal) {
                                        Text(verbatim: meeting.subtitle).lineLimit(1)
                                        Text(verbatim: meeting.subtitle).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .ataCallout()
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: Theme.Space.s)
                                Image(systemName: "chevron.right")
                                    .ataFont(11, weight: .semibold) // 11 pt semibold; ataCaption is regular
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var firstRun: some View {
        Card(padding: Theme.Space.l) {
            EmptyState(icon: "waveform",
                       title: L("Your meetings will appear here"),
                       message: L("Record 30 seconds to see how it works."))
        }
        .accessibilityIdentifier("record-first-run")
    }

    // MARK: Free minutes

    private var quotaCard: some View {
        Button {
            ProPromptCenter.shared.openPaywall(store.needsPro ? .limit : .recordHome)
        } label: {
            Card(padding: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    QuotaMeter(usedMinutes: store.freeUsed, limitMinutes: FreeQuota.limitMinutes)
                    HStack {
                        Text("Try Ata Pro")
                            .ataHeadline()
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: Theme.Space.s)
                        Image(systemName: "chevron.right")
                            .ataFont(11, weight: .semibold) // 11 pt semibold; ataCaption is regular
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Tip

    private func tipBanner(_ tip: RecordHomeModel.Tip) -> some View {
        Banner(kind: .info, mark: .symbol("lightbulb"), title: Text(verbatim: Self.text(tip)),
               dismiss: {
                   var dismissed = RecordHomeModel.decodeTips(dismissedTips)
                   dismissed.insert(tip)
                   withAnimation { dismissedTips = RecordHomeModel.encodeTips(dismissed) }
               })
    }

    private static func text(_ tip: RecordHomeModel.Tip) -> String {
        switch tip {
        case .lockScreen: return L("Add the Record with Ata control to your Lock Screen or Control Center.")
        case .actionButton: return L("On an iPhone with an Action button, you can set it to Record with Ata.")
        case .siri: return L("Say “Record with Ata” to Siri to start a recording.")
        case .widget: return L("Add the Ata widget to your Home Screen to see your last meeting.")
        }
    }
}
