import SwiftUI

/// Every meeting on this iPhone, newest first, with search. A meeting opens in
/// the same `MeetingView` the Mac shows in its window.
struct MeetingsList: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var navigation: PhoneNavigation
    @State private var query = ""
    @State private var pendingDelete: Meeting?
    @State private var choosingAudio = false
    /// Not Insights' filter: choosing Work there used to hide meetings here, with
    /// no control on this screen unless a search was open.
    @AppStorage(Pref.meetingsCategoryFilter) private var categoryFilter = ""
    /// Search hits, recomputed when the query or the library changes — not on
    /// every transcription tick, which would stat every transcript again.
    @State private var searched: [Meeting] = []

    private var shown: [Meeting] {
        let inCategory = store.meetings.filter { MeetingCategory.matches($0, filter: categoryFilter) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return inCategory }
        return searched
    }

    var body: some View {
        NavigationStack(path: $navigation.meetingPath) {
            List {
                if store.importing > 0 {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Importing audio…").foregroundStyle(.secondary)
                        }
                    }
                }
                if store.waitingForEngine {
                    Section {
                        Label("Recordings wait here until this iPhone can transcribe them. The audio is kept.",
                              systemImage: "hourglass")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(shown) { meeting in
                    NavigationLink(value: meeting.id) {
                        PhoneMeetingRow(meeting: meeting,
                                        progress: store.transcribingID == meeting.id ? store.transcribeProgress : nil,
                                        stage: store.transcribingID == meeting.id ? store.transcribeStage : nil)
                    }
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = meeting } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(!store.canDelete(meeting))
                    }
                }
            }
            .overlay {
                if MeetingsPlaceholder.shown(meetings: store.meetings.count, importing: store.importing,
                                             waitingForEngine: store.waitingForEngine) {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Record one and your history shows up here."))
                } else if shown.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if shown.isEmpty {
                    ContentUnavailableView("No meetings here yet", systemImage: "tag",
                                           description: Text("Pick Work or Personal in a meeting to file it here."))
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // Above the list, and above the empty state, so a filter that
                // matches nothing can still be cleared.
                if query.trimmingCharacters(in: .whitespaces).isEmpty,
                   !categoryFilter.isEmpty, let name = MeetingCategory(rawValue: categoryFilter)?.name {
                    HStack(spacing: 8) {
                        Text(verbatim: name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(L("All")) { categoryFilter = "" }
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
            .searchable(text: $query, prompt: Text("Search meetings"))
            .searchScopes($categoryFilter, activation: .onSearchPresentation) {
                Text("All").tag("")
                ForEach(MeetingCategory.allCases) { c in Text(c.name).tag(c.rawValue) }
            }
            .refreshable { store.reload() }
            .navigationTitle("Meetings")
            // Audio recorded elsewhere: Voice Memos, a recorder, a file someone sent.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    // Past the free meetings, Pro comes first. Files already on
                    // their way in (shared, opened in Ata) are never refused.
                    Button {
                        store.updateQuota()
                        if store.needsPro { PhoneNavigation.shared.showPaywall() } else { choosingAudio = true }
                    } label: {
                        Label("Import audio…", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .fileImporter(isPresented: $choosingAudio, allowedContentTypes: AudioImport.types,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): store.importAudio(urls)
                case .failure(let error): store.importError = error.localizedDescription
                }
            }
            .onChange(of: query, initial: true) { _, _ in refreshSearch() }
            .onChange(of: store.meetings) { _, _ in refreshSearch() }
            .onChange(of: categoryFilter) { _, _ in refreshSearch() }
            .navigationDestination(for: String.self) { id in
                MeetingScreen(id: id)
            }
            .alert(store.deleteError ?? "", isPresented: Binding(
                get: { store.deleteError != nil },
                set: { if !$0 { store.deleteError = nil } }
            )) {
                Button(L("Close"), role: .cancel) {}
            }
            .confirmationDialog(L("Delete this meeting?"), isPresented: deleting, titleVisibility: .visible,
                                presenting: pendingDelete) { meeting in
                Button(L("Delete"), role: .destructive) { store.delete(meeting) }
            } message: { _ in
                Text(CloudLibrary.isActive
                     ? L("The recording, the transcript and your notes are deleted from iCloud, on every device.")
                     : L("The recording, the transcript and your notes are deleted from this iPhone."))
            }
        }
    }

    private func refreshSearch() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let inCategory = store.meetings.filter { MeetingCategory.matches($0, filter: categoryFilter) }
        guard !q.isEmpty else { searched = inCategory; return }
        searched = inCategory.filter { store.searchText(for: $0).contains(q) }
    }

    private var deleting: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

private struct PhoneMeetingRow: View {
    let meeting: Meeting
    let progress: Double?
    let stage: TranscribeStage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.subtitle).font(.subheadline).foregroundStyle(.secondary)
                CategoryTagView(category: meeting.categoryValue)
            }
            status
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var status: some View {
        if meeting.isPlaceholder {
            Label("Downloading from iCloud…", systemImage: "icloud.and.arrow.down")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            statusLine
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch meeting.status {
        case .pending:
            if let error = meeting.error {
                Text(verbatim: error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Waiting to be transcribed…").font(.caption).foregroundStyle(.secondary)
            }
        case .transcribing:
            if let progress {
                ProgressView(value: progress) {
                    if let stage {
                        Text(verbatim: stage.label).font(.caption)
                    } else {
                        Text("Transcribing…").font(.caption)
                    }
                }
            } else {
                Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed:
            Text(meeting.error ?? L("Failed")).font(.caption).foregroundStyle(.red).lineLimit(2)
        case .recording:
            Text("Recording…").font(.caption).foregroundStyle(.red)
        case .done:
            EmptyView()
        }
    }
}

/// One meeting, pushed from the list. The model is made once per screen, not on
/// every redraw of the list.
private struct MeetingScreen: View {
    @StateObject private var model: MeetingModel

    init(id: String) {
        _model = StateObject(wrappedValue: MeetingModel(id: id))
    }

    var body: some View {
        MeetingView(model: model)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Switching tabs closes the player. Coming back has to be able to play.
                if let meeting = model.meeting, !model.player.loaded {
                    model.player.load(meeting)
                }
            }
            .onDisappear { model.close() }
    }
}
