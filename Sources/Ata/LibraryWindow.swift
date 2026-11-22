#if os(macOS)
import AppKit
import SwiftUI

/// Date sections for the library. Newest first, within a section and across them.
///
/// Today, yesterday, and the rest of this month are named. Older months use the
/// month (and the year, once it is not this one). A recording is never dated
/// ahead of now; a future day in this month still shares "Earlier this month"
/// so the list does not grow a second heading for the same month.
enum LibrarySections {
    enum Bucket: Hashable, Equatable {
        case today
        case yesterday
        case earlierThisMonth
        case month(year: Int, month: Int)
    }

    struct Group: Equatable, Identifiable {
        var bucket: Bucket
        var meetings: [Meeting]
        var id: Bucket { bucket }
    }

    static func group(_ meetings: [Meeting], now: Date, calendar: Calendar = .current) -> [Group] {
        let sorted = meetings.sorted { $0.startedAt > $1.startedAt }
        var buckets: [Bucket: [Meeting]] = [:]
        for meeting in sorted {
            buckets[bucket(for: meeting.startedAt, now: now, calendar: calendar), default: []].append(meeting)
        }
        return buckets.map { Group(bucket: $0.key, meetings: $0.value) }
            .sorted { rank($0.bucket) < rank($1.bucket) }
    }

    static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> Bucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        if year == calendar.component(.year, from: now),
           month == calendar.component(.month, from: now) { return .earlierThisMonth }
        return .month(year: year, month: month)
    }

    /// Already localized. `SectionLabel` draws it in small caps.
    static func title(for bucket: Bucket, now: Date, calendar: Calendar = .current) -> String {
        switch bucket {
        case .today: return L("Today")
        case .yesterday: return L("Yesterday")
        case .earlierThisMonth: return L("Earlier this month")
        case .month(let year, let month):
            var parts = DateComponents()
            parts.calendar = calendar
            parts.timeZone = calendar.timeZone
            parts.year = year
            parts.month = month
            parts.day = 1
            let date = calendar.date(from: parts) ?? now
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = .autoupdatingCurrent
            formatter.timeZone = calendar.timeZone
            let sameYear = year == calendar.component(.year, from: now)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM yyyy")
            return formatter.string(from: date)
        }
    }

    /// Today, then yesterday, then the rest of this month, then months newest first.
    private static func rank(_ bucket: Bucket) -> (Int, Int) {
        switch bucket {
        case .today: return (0, 0)
        case .yesterday: return (1, 0)
        case .earlierThisMonth: return (2, 0)
        case .month(let year, let month): return (3, -(year * 12 + month))
        }
    }
}

/// Which pane the library window is showing. The menu's "See all" and the
/// voices chip set it, including when the window is already open.
@MainActor
final class LibraryNavigation: ObservableObject {
    static let shared = LibraryNavigation()
    @Published var pane: LibraryWindow.Pane? = .meetings
}

/// The free-minute bar and the Ata Pro link. Hidden for Pro, and hidden until
/// the Mac quota applies. Both the menu and the library sidebar use it.
struct FreeQuotaFooter: View {
    enum Layout { case inline, stacked }
    var layout: Layout = .inline
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var access = ProAccess.shared

    private var shows: Bool { FreeQuota.appliesOnMac && !access.isPro }

    var body: some View {
        if shows {
            switch layout {
            case .inline:
                HStack(alignment: .center, spacing: Theme.Space.s) {
                    meter
                    proButton.fixedSize()
                }
            case .stacked:
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    meter
                    proButton
                }
            }
        }
    }

    private var meter: some View {
        QuotaMeter(usedMinutes: store.freeUsed, limitMinutes: FreeQuota.limitMinutes)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var proButton: some View {
        Button { WindowManager.shared.showPro(trigger: .recordHome) } label: {
            HStack(spacing: 2) {
                Text("Ata Pro")
                Image(systemName: "chevron.right")
                    .ataFont(10, weight: .semibold)
            }
            .ataCaption()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
    }
}

/// Ata's window: record, the meeting library, Insights and People.
/// 900×620, and never smaller than 720×480.
struct LibraryWindow: View {
    enum Pane: Hashable { case meetings, insights, people }

    static let opening = NSSize(width: 900, height: 620)
    static let minSize = NSSize(width: 720, height: 480)
    /// Ideal sidebar. The snapshot split uses it directly; the live split
    /// allows the same column to flex between 180 and 260.
    static let sidebarWidth: CGFloat = 210
    /// Insights and People stay readable; the meeting list uses the whole column.
    static let contentMaxWidth: CGFloat = 720

    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var setup: SetupModel
    @ObservedObject private var navigation = LibraryNavigation.shared
    @ObservedObject private var access = ProAccess.shared
    @AppStorage(Pref.categoryFilter) private var categoryFilter = ""
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var groups: [LibrarySections.Group] = []
    @State private var transcripts = TranscriptCache()
    @FocusState private var searchFocused: Bool

    /// A row of People already open, for the screenshots.
    private let openPerson: PeopleList.Row?
    /// The voice "Same person as" is choosing for, for the screenshots.
    private let mergingPerson: Voice?

    init(openPerson: PeopleList.Row? = nil, mergingPerson: Voice? = nil) {
        self.openPerson = openPerson
        self.mergingPerson = mergingPerson
    }

    private var pane: Pane { navigation.pane ?? .meetings }

    private var meetings: [Meeting] {
        Snapshots.omitMeetings ? [] : store.meetings
    }

    var body: some View {
        columnsView
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .background {
            VStack {
                Button("") { store.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { openSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(searchFocused || selectedID == nil)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onAppear {
            setup.refresh()
            if !Snapshots.rendering {
                store.reload()
                store.writeOwedSummaries()
            }
            refresh()
        }
        .onChange(of: store.meetings) { _, _ in refresh() }
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: categoryFilter) { _, _ in refresh() }
        .tint(Theme.accent)
    }

    /// The sidebar and the detail. The real window uses `NavigationSplitView`.
    /// Its sidebar is a visual-effect view, and those draw nothing into the
    /// offscreen bitmap the README renderer uses, so that path uses the same
    /// sidebar in a plain split.
    @ViewBuilder private var columnsView: some View {
        if Snapshots.rendering {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: Self.sidebarWidth)
                    .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            NavigationSplitView(columnVisibility: $columns) {
                sidebar
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            recordButton
                .padding(.horizontal, Theme.Space.s)
                .padding(.top, Theme.Space.m)
                .padding(.bottom, Theme.Space.xs)
            List(selection: $navigation.pane) {
                Label("Meetings", systemImage: "list.bullet").tag(Pane.meetings)
                Label("Insights", systemImage: "chart.bar").tag(Pane.insights)
                Label("People", systemImage: "person.2").tag(Pane.people)
            }
            .listStyle(.sidebar)
            // The sidebar column already paints the background. A second fill
            // here leaves the record button and the quota on a different colour.
            .scrollContentBackground(.hidden)
            if FreeQuota.appliesOnMac, !access.isPro {
                Divider().padding(.horizontal, Theme.Space.m)
                FreeQuotaFooter(layout: .stacked)
                    .padding(Theme.Space.m)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 180, ideal: Self.sidebarWidth, max: 260)
    }

    private var recordButton: some View {
        let recording = store.phase == .recording || store.phase == .stopping
        return Button { store.toggleRecording() } label: {
            HStack(spacing: Theme.Space.s) {
                if recording {
                    PulsingDot()
                } else {
                    Circle()
                        .fill(Theme.recordingSolid)
                        .frame(width: 8, height: 8)
                }
                Text(recording ? "Stop and transcribe" : "Record")
                    .ataHeadline()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.phase == .starting || store.phase == .stopping)
        .help(recording ? L("Stop and transcribe") : L("Start recording (⌘R)"))
        .accessibilityLabel(recording ? L("Stop and transcribe") : L("Record"))
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch pane {
        case .meetings:
            meetingsDetail
        case .insights:
            ScrollView {
                InsightsView()
                    .padding(Theme.Space.l)
                    .frame(maxWidth: Self.contentMaxWidth)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .people:
            PeopleView(open: openPerson, merging: mergingPerson, fills: true)
                .padding(Theme.Space.l)
                .frame(maxWidth: Self.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var meetingsDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search meetings", text: $query, prompt: Text("Search meetings"))
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                CategoryFilterPicker(selection: $categoryFilter)
                    .frame(maxWidth: 260)
            }
            .padding(Theme.Space.l)

            if meetings.isEmpty {
                FirstMeetingsCard()
                    .padding(.horizontal, Theme.Space.l)
                Spacer(minLength: 0)
            } else if groups.isEmpty {
                EmptyState(icon: "magnifyingglass",
                           title: queryNeedsTranscript ? L("No meetings match this search") : L("No meetings here yet"),
                           message: "")
                    .padding(Theme.Space.xl)
                Spacer(minLength: 0)
            } else {
                List(selection: $selectedID) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.meetings) { meeting in
                                MeetingRow(meeting: meeting, activation: .doubleClick)
                                    .tag(meeting.id)
                                    .listRowInsets(EdgeInsets(top: 0, leading: Theme.Space.s,
                                                              bottom: 0, trailing: Theme.Space.m))
                                    .listRowSeparator(.hidden)
                            }
                        } header: {
                            SectionLabel(LibrarySections.title(for: group.bucket, now: Date()))
                        }
                    }
                }
                .listStyle(.inset)
                .onKeyPress(.return) {
                    guard !searchFocused, selectedID != nil else { return .ignored }
                    openSelected()
                    return .handled
                }
            }
        }
    }

    private var queryNeedsTranscript: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refresh() {
        let now = Date()
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = meetings.filter { meeting in
            guard MeetingCategory.matches(meeting, filter: categoryFilter) else { return false }
            let transcript = wanted.isEmpty ? "" : transcripts.text(for: meeting)
            return meeting.matches(wanted, transcript: transcript)
        }
        groups = LibrarySections.group(filtered, now: now)
        if let selectedID, !filtered.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func openSelected() {
        guard let selectedID else { return }
        WindowManager.shared.showMeeting(selectedID)
    }
}

/// Transcript text for the search field, read once per file change. The match
/// itself is `Meeting.matches`; this only keeps the disk read off the keystroke.
private final class TranscriptCache {
    var entries: [String: (stamp: Date?, text: String)] = [:]

    func text(for meeting: Meeting) -> String {
        let url = meeting.existingTranscriptURL
        let stamp = url.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        if let cached = entries[meeting.id], cached.stamp == stamp { return cached.text }
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        entries[meeting.id] = (stamp, text)
        return text
    }
}
#endif
