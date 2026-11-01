import Charts
import SwiftUI

/// The menu's second tab: what you've recorded and who talked.
struct InsightsView: View {
    @EnvironmentObject var store: AppStore
    @State private var data = Insights()
    /// Drives every entrance animation: charts grow and numbers count up from zero.
    @State private var shown = false
    /// The same filter as the meeting list: Insights for work alone, or for the rest.
    @AppStorage(Pref.categoryFilter) private var categoryFilter = ""

    private var myName: String { Pref.myNameOrDefault }

    /// Always the default on the Mac, which has no Text Size setting.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var stacked: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.meetings.isEmpty {
                CategoryFilterPicker(selection: $categoryFilter)
                    .controlSize(.small)
            }
            if data.isEmpty {
                empty
            } else {
                tiles
                weeksCard
                // Side by side, unless the iPhone's text is so large that the
                // names and numbers no longer fit in half the width.
                let pair = stacked ? AnyLayout(VStackLayout(spacing: 10))
                                   : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                pair {
                    talkCard
                    appsCard
                }
                .fixedSize(horizontal: false, vertical: true)
                timelineCard
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: store.meetings) { _, _ in refresh() }
        .onChange(of: categoryFilter) { _, _ in refresh() }
    }

    private func refresh() {
        let meetings = store.meetings.filter { MeetingCategory.matches($0, filter: categoryFilter) }
        let computed = Insights.compute(meetings, myName: myName)
        guard computed != data || !shown else { return }
        data = computed
        if Snapshots.rendering {
            shown = true
        } else {
            shown = false
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.05)) { shown = true }
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        Group {
            if stacked {
                VStack(spacing: 8) {
                    recordedTile
                    meetingsTile
                    wordsTile
                    monthTile
                }
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        recordedTile
                        meetingsTile
                    }
                    GridRow {
                        wordsTile
                        monthTile
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var recordedTile: some View {
        Tile(symbol: "waveform", tint: Theme.meTint, title: L("Recorded"),
             value: hours(shown ? data.recordedSeconds : 0))
    }

    private var meetingsTile: some View {
        Tile(symbol: "person.2.fill", tint: Theme.othersTint, title: L("Meetings"),
             value: "\(shown ? data.meetings : 0)")
    }

    private var wordsTile: some View {
        Tile(symbol: "text.word.spacing", tint: .orange, title: L("Words"),
             value: (shown ? data.words : 0).formatted(.number.notation(.compactName)))
    }

    private var monthTile: some View {
        Tile(symbol: "calendar", tint: .pink, title: L("This month"),
             value: hours(shown ? data.recordedThisMonth : 0))
    }

    private func hours(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? L("%dh %02dm", minutes / 60, minutes % 60) : L("%d min", minutes)
    }

    // MARK: Weeks

    private var weeksCard: some View {
        InsightCard(title: L("Last 8 weeks"), trailing: L("minutes recorded")) {
            Chart(data.weeks) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear),
                        y: .value("Minutes", shown ? week.minutes : 0))
                    .foregroundStyle(Theme.brand)
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel()
                }
            }
            .chartYScale(domain: 0...max(30, (data.weeks.map(\.minutes).max() ?? 0) * 1.15))
            .frame(height: 110)
        }
    }

    // MARK: Talk time

    private var talkCard: some View {
        InsightCard(title: L("Who talks")) {
            // The ring above its legend: beside it, half a menu's width left
            // no room for a name and its share.
            VStack(spacing: 8) {
                Chart {
                    SectorMark(angle: .value("You", shown ? max(data.mySpeech, 0.001) : 0.001),
                               innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(Theme.meTint)
                        .cornerRadius(3)
                    SectorMark(angle: .value("Others", shown ? max(data.othersSpeech, 0.001) : 1),
                               innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(Theme.othersTint)
                        .cornerRadius(3)
                }
                .frame(width: 62, height: 62)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                // Each share next to its own name: a lone "40%" in the ring
                // didn't say whose 40% it was.
                VStack(alignment: .leading, spacing: 4) {
                    legend(myName, Theme.meTint, percent: data.talkPercents?.mine)
                    legend(L("Others"), Theme.othersTint, percent: data.talkPercents?.others)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color, percent: Int?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).ataFont(11).lineLimit(1)
            if let percent {
                Spacer(minLength: 4)
                Text(verbatim: "\(shown ? percent : 0)%")
                    .ataFont(11, weight: .bold, design: .rounded)
                    .monospacedDigit()
                    .fixedSize()
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Apps

    private var appsCard: some View {
        InsightCard(title: L("Where")) {
            VStack(alignment: .leading, spacing: 5) {
                let top = data.apps.first?.minutes ?? 1
                ForEach(data.apps) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(app.name).ataFont(10, weight: .medium).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(Insights.duration(minutes: app.minutes))
                                .ataFont(10).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                        GeometryReader { geo in
                            Capsule()
                                .fill(Theme.othersTint.opacity(0.85))
                                .frame(width: max(4, geo.size.width * (shown ? app.minutes / top : 0)))
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
    }

    // MARK: Timeline

    private var timelineCard: some View {
        InsightCard(title: L("Transcriptions")) {
            VStack(spacing: 6) {
                ForEach(Array(data.timeline.prefix(4).enumerated()), id: \.element.id) { i, event in
                    TimelineRow(event: event)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 6)
                        .animation(.easeOut(duration: 0.4).delay(Snapshots.rendering ? 0 : 0.25 + Double(i) * 0.07),
                                   value: shown)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .ataFont(28)
                .foregroundStyle(Theme.brand)
            Text("No meetings yet").ataFont(13, weight: .semibold)
            Text("Record one and your history shows up here.")
                .ataFont(11).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct Tile: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).ataFont(10, weight: .semibold).foregroundStyle(tint)
                Text(title.uppercased()).ataFont(9, weight: .semibold).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .ataFont(19, weight: .bold, design: .rounded)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let footnote {
                Text(footnote).ataFont(9).foregroundStyle(.green).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

private struct InsightCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).ataFont(9, weight: .semibold).foregroundStyle(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing).ataFont(9).ataFaint()
                }
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

private struct TimelineRow: View {
    let event: Insights.Event

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: event.record.isLocal ? "cpu" : "cloud")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(event.record.isLocal ? Theme.meTint : .pink)
                .frame(width: 20, height: 20)
                .background(Circle().fill((event.record.isLocal ? Theme.meTint : .pink).opacity(0.14)))
            VStack(alignment: .leading, spacing: 0) {
                Text(event.meetingTitle).ataFont(11, weight: .semibold).lineLimit(1)
                Text((LocalModel.find(event.record.model)?.title ?? event.record.model) + (event.isCurrent ? "" : " · " + L("replaced")))
                    .ataFont(10).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(event.record.finishedAt, format: .relative(presentation: .named))
                    .ataFont(9).ataFaint()
            }
        }
    }
}
