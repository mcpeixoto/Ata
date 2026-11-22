import SwiftUI

/// Meetings the question is asked against: one source per transcript on disk.
enum AskLibrary {
    static func sources(from meetings: [Meeting]) -> [AskSource] {
        meetings.compactMap { meeting in
            guard let url = meeting.existingTranscriptURL,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.isEmpty else { return nil }
            return AskSource(id: meeting.id, title: meeting.title, transcript: text)
        }
    }
}

/// `[Title · mm:ss]` in an answer, matched to the meeting that title names.
enum AskChips {
    struct Chip: Equatable, Identifiable {
        var meetingID: String
        var title: String
        var stamp: String
        var milliseconds: Int
        var id: String { "\(meetingID)|\(milliseconds)|\(title)" }
    }

    static func chips(in text: String, meetings: [AskSource]) -> [Chip] {
        AskCitations.parse(text).compactMap { citation in
            guard let meeting = meetings.first(where: { $0.title == citation.title }) else { return nil }
            return Chip(meetingID: meeting.id, title: citation.title, stamp: citation.stamp,
                        milliseconds: citation.milliseconds)
        }
    }

    /// The answer with matched citations taken out, so the chips are not also
    /// left in the sentence as brackets.
    static func prose(in text: String, meetings: [AskSource]) -> String {
        var result = text
        for chip in chips(in: text, meetings: meetings) {
            result = result.replacingOccurrences(of: AskCitations.mark(title: chip.title, stamp: chip.stamp), with: "")
        }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A question across the meetings on this device. Hidden by the caller unless
/// Apple Intelligence is available. Free users can type and read the examples;
/// sending the question opens the paywall.
struct AskView: View {
    /// A finished answer for the screenshots. No model call.
    struct Fixture {
        var question: String
        var answer: String?
        var meetings: [AskSource]
    }

    var fixture: Fixture? = nil

    @State private var question: String
    @State private var asking = false
    @State private var asked: Bool
    @State private var result: AskMeetings.Answer?
    @State private var sources: [AskSource]
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    init(fixture: Fixture? = nil) {
        self.fixture = fixture
        _question = State(initialValue: fixture?.question ?? "")
        _asked = State(initialValue: fixture != nil)
        _result = State(initialValue: fixture?.answer.map {
            AskMeetings.Answer(text: $0, citations: AskCitations.parse($0))
        })
        _sources = State(initialValue: fixture?.meetings ?? [])
    }

    private var examples: [String] {
        [
            L("What did we decide about pricing?"),
            L("What are my open action items?"),
            L("What did the client ask for?"),
        ]
    }

    var body: some View {
        #if os(iOS)
        NavigationStack { content.toolbar { done } }
        #else
        content
        #endif
    }

    #if os(iOS)
    private var done: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
    }
    #endif

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Ask your meetings")
                    .ataLargeTitle()
                field
                exampleChips
                if asking {
                    progress
                } else if asked {
                    outcome
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: load)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            TextField("Ask about your meetings", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .ataBody()
                .onSubmit(ask)
            Button(action: ask) {
                Text("Ask")
                    .ataHeadline()
                    .foregroundStyle(Theme.accentInk)
                    .frame(maxWidth: .infinity, minHeight: PrimaryButtonStyle.height)
                    .background(Capsule().fill(Theme.brand))
            }
            .buttonStyle(.plain)
            .disabled(asking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var exampleChips: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(examples, id: \.self) { example in
                Button {
                    question = example
                    ask()
                } label: {
                    Text(verbatim: example)
                        .ataCallout()
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var progress: some View {
        HStack(spacing: Theme.Space.s) {
            ProgressView()
            Text("Looking through your meetings…")
                .ataCallout()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var outcome: some View {
        if let result {
            let chips = AskChips.chips(in: result.text, meetings: sources)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(verbatim: AskChips.prose(in: result.text, meetings: sources))
                    .ataBody()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(chips) { chip in
                    Button { open(chip) } label: {
                        Text(verbatim: chip.title + AskCitations.separator + chip.stamp)
                            .ataCaption()
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, Theme.Space.xs)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Text("No answer found in your meetings")
                .ataBody()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() {
        guard fixture == nil else { return }
        sources = AskLibrary.sources(from: Library.loadAll())
    }

    private func ask() {
        // The screenshot is a finished answer. It must not call the model.
        if fixture != nil { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        guard ProGate.lockedTap(.askMeetings, isPro: ProGate.allows(.askMeetings)) else { return }
        asking = true
        asked = true
        result = nil
        let meetings = sources
        Task {
            let found = await AskMeetings.answer(question: q, meetings: meetings)
            result = found
            asking = false
        }
    }

    private func open(_ chip: AskChips.Chip) {
        WindowManager.shared.showMeeting(chip.meetingID, atMs: chip.milliseconds)
        #if os(iOS)
        dismiss()
        #endif
    }
}
