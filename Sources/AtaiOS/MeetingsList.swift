import SwiftUI

/// Every meeting on this iPhone, newest first, with search. A meeting opens in
/// the same `MeetingView` the Mac shows in its window.
struct MeetingsList: View {
    @EnvironmentObject var store: PhoneStore
    @EnvironmentObject var navigation: PhoneNavigation
    @State private var query = ""
    @State private var pendingDelete: Meeting?

    private var shown: [Meeting] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.meetings }
        return store.meetings.filter { store.searchText(for: $0).contains(q) }
    }

    var body: some View {
        NavigationStack(path: $navigation.meetingPath) {
            List {
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
                                        progress: store.transcribingID == meeting.id ? store.transcribeProgress : nil)
                    }
                    .swipeActions {
                        Button(role: .destructive) { pendingDelete = meeting } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(meeting.id == store.transcribingID || meeting.status == .recording)
                    }
                }
            }
            .overlay {
                if store.meetings.isEmpty {
                    ContentUnavailableView("No meetings yet", systemImage: "waveform",
                                           description: Text("Record one and your history shows up here."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: Text("Search meetings"))
            .refreshable { store.reload() }
            .navigationTitle("Meetings")
            .navigationDestination(for: String.self) { id in
                MeetingScreen(id: id)
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

    private var deleting: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

private struct PhoneMeetingRow: View {
    let meeting: Meeting
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).font(.headline).lineLimit(1)
            Text(meeting.subtitle).font(.subheadline).foregroundStyle(.secondary)
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
            Text("Waiting to be transcribed…").font(.caption).foregroundStyle(.secondary)
        case .transcribing:
            if let progress {
                ProgressView(value: progress) { Text("Transcribing…").font(.caption) }
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
            .onDisappear { model.close() }
    }
}
