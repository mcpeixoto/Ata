import SwiftUI

/// The sample shown to everyone, including people who are not Pro. It is not
/// saved, and it cannot be edited: it exists so the editor is visible before
/// a subscription.
enum TemplateExample {
    static let id = UUID(uuidString: "E1A00000-0000-4000-8000-0000000000C1")!

    static var template: CustomTemplate {
        CustomTemplate(
            id: id,
            name: L("Example: Client call"),
            instructions: L("A call with a client. Write what they need, what concerns them, and the next step that was agreed. Leave out small talk."),
            sections: [L("What they need"), L("Concerns"), L("Next step")]
        )
    }

    static func isExample(_ template: CustomTemplate) -> Bool { template.id == id }
}

/// What the instructions field stores, and what its counter counts. Longer text
/// is cut here, the same way a saved template is cut.
enum TemplateDraft {
    static func instructions(_ text: String) -> String { CustomTemplate.capped(text) }
}

/// The list the editor shows: the example first, then the templates on this device.
enum TemplateListModel {
    struct Row: Equatable, Identifiable {
        var template: CustomTemplate
        var isExample: Bool
        /// False for the example, and for every template while the user is not Pro.
        var canEdit: Bool
        var id: UUID { template.id }
    }

    static func rows(saved: [CustomTemplate], isPro: Bool) -> [Row] {
        let example = Row(template: TemplateExample.template, isExample: true, canEdit: false)
        let own = saved.filter { !TemplateExample.isExample($0) }.map {
            Row(template: $0, isExample: false, canEdit: isPro)
        }
        return [example] + own
    }

    /// Free users see the paywall card under the title. Pro does not.
    static func showsUnlockCard(isPro: Bool) -> Bool { !isPro }

    /// The example is always listed, so this is "nothing of their own yet".
    static func showsEmptyLine(saved: [CustomTemplate], isPro: Bool) -> Bool {
        isPro && saved.allSatisfy(TemplateExample.isExample)
    }

    static func addSymbol(isPro: Bool) -> String { isPro ? "plus" : "lock.fill" }
}

private struct SectionDraft: Identifiable, Equatable {
    var id = UUID()
    var text: String
}

private struct EditorRequest: Identifiable {
    var id: String
    var template: CustomTemplate?
    var readOnly: Bool
}

/// The user's templates, plus the read-only example. Free users see a lock and
/// the paywall instead of the editor; the example still opens.
struct TemplateListView: View {
    /// Snapshot stand-in. Nil reads `templates.json`.
    var fixtureTemplates: [CustomTemplate]? = nil
    /// Snapshot stand-in for `ProAccess`. Nil follows the live entitlement.
    var fixturePro: Bool? = nil

    @ObservedObject private var access = ProAccess.shared
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [CustomTemplate]
    @State private var editor: EditorRequest?
    @State private var pendingDelete: CustomTemplate?
    @State private var saveError: String?

    init(fixtureTemplates: [CustomTemplate]? = nil, fixturePro: Bool? = nil) {
        self.fixtureTemplates = fixtureTemplates
        self.fixturePro = fixturePro
        _templates = State(initialValue: fixtureTemplates ?? [])
    }

    private var isPro: Bool { fixturePro ?? access.isPro }

    private var rows: [TemplateListModel.Row] {
        TemplateListModel.rows(saved: templates, isPro: isPro)
    }

    var body: some View {
        sheetHost
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
        .alert(saveError ?? "", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button(L("Close"), role: .cancel) {}
        }
    }

    /// A macOS sheet draws neither `.navigationTitle` nor `.toolbar`, and the
    /// snapshot renderer doesn't either, so the title and the actions are in
    /// the content. The iPhone keeps the bar it already had.
    @ViewBuilder private var sheetHost: some View {
        #if os(iOS)
        NavigationStack {
            page
                .navigationTitle("Your templates")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { add() } label: {
                            Label("Add template", systemImage: TemplateListModel.addSymbol(isPro: isPro))
                        }
                    }
                }
        }
        #else
        page
        #endif
    }

    private var page: some View {
        VStack(spacing: 0) {
            List {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(headerInsets)
                if TemplateListModel.showsUnlockCard(isPro: isPro) {
                    unlockCard
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(chromeInsets)
                }
                if TemplateListModel.showsEmptyLine(saved: templates, isPro: isPro) {
                    Text("No templates yet. Add one to use it from any meeting's summary.")
                        .ataCallout()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                        .listRowInsets(chromeInsets)
                }
                ForEach(rows) { row in
                    Button { open(row) } label: {
                        HStack(spacing: Theme.Space.s) {
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                Text(verbatim: row.template.name)
                                    .ataHeadline()
                                    .foregroundStyle(.primary)
                                if row.isExample {
                                    Text("Example")
                                        .ataCaption()
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: Theme.Space.s)
                            if !isPro, !row.isExample {
                                Image(systemName: "lock.fill")
                                    .ataCaption()
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(L("Locked"))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !row.isExample {
                            Button("Delete", role: .destructive) { pendingDelete = row.template }
                        }
                    }
                }
            }
            .scrollContentBackground(Snapshots.rendering ? .hidden : .automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editor) { request in
            TemplateEditorSheet(template: request.template, readOnly: request.readOnly) { saved in
                store(saved)
            }
        }
        .confirmationDialog(L("Delete this template?"), isPresented: deleting, titleVisibility: .visible,
                            presenting: pendingDelete) { template in
            Button(L("Delete"), role: .destructive) { remove(template) }
        } message: { template in
            Text(verbatim: template.name)
        }
        .onAppear(perform: reload)
    }

    private var headerInsets: EdgeInsets {
        EdgeInsets(top: Theme.Space.l, leading: Theme.Space.l, bottom: Theme.Space.s, trailing: Theme.Space.l)
    }

    private var chromeInsets: EdgeInsets {
        EdgeInsets(top: Theme.Space.s, leading: Theme.Space.l, bottom: Theme.Space.s, trailing: Theme.Space.l)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Your templates")
                .ataTitle()
                .accessibilityAddTraits(.isHeader)
            Text("Your own summary formats. Ata writes the summary in the sections you choose.")
                .ataCallout()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unlockCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "lock.fill")
                        .ataHeadline()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Your own templates are part of Ata Pro.")
                        .ataBody()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    _ = ProGate.lockedTap(.customTemplates, isPro: false)
                } label: {
                    Text("Unlock with Ata Pro")
                        .ataHeadline()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            Button(action: add) {
                Label("Add template", systemImage: TemplateListModel.addSymbol(isPro: isPro))
                    .ataHeadline()
            }
            .buttonStyle(.bordered)
            Spacer(minLength: Theme.Space.s)
            #if os(macOS)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            #endif
        }
        .padding(Theme.Space.l)
    }

    private var deleting: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func reload() {
        guard fixtureTemplates == nil else { return }
        templates = TemplateLibrary.load(from: Paths.supportDir)
    }

    private func open(_ row: TemplateListModel.Row) {
        if row.isExample {
            editor = EditorRequest(id: row.id.uuidString, template: row.template, readOnly: true)
            return
        }
        guard ProGate.lockedTap(.customTemplates, isPro: isPro) else { return }
        editor = EditorRequest(id: row.id.uuidString, template: row.template, readOnly: false)
    }

    private func add() {
        guard ProGate.lockedTap(.customTemplates, isPro: isPro) else { return }
        editor = EditorRequest(id: "new", template: nil, readOnly: false)
    }

    private func store(_ template: CustomTemplate) {
        var next = templates.filter { !TemplateExample.isExample($0) }
        if let index = next.firstIndex(where: { $0.id == template.id }) {
            next[index] = template
        } else {
            next.append(template)
        }
        write(next)
    }

    private func remove(_ template: CustomTemplate) {
        write(templates.filter { $0.id != template.id && !TemplateExample.isExample($0) })
    }

    private func write(_ next: [CustomTemplate]) {
        if fixtureTemplates != nil {
            templates = next
            return
        }
        do {
            try TemplateLibrary.save(next)
            templates = next
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// Name, instructions and sections for one template. The example opens this
/// with `readOnly`, so Save is not offered.
struct TemplateEditorSheet: View {
    var template: CustomTemplate?
    var readOnly: Bool
    var onSave: (CustomTemplate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var instructions: String
    @State private var sections: [SectionDraft]

    init(template: CustomTemplate? = nil, readOnly: Bool = false, onSave: @escaping (CustomTemplate) -> Void = { _ in }) {
        self.template = template
        self.readOnly = readOnly
        self.onSave = onSave
        _name = State(initialValue: template?.name ?? "")
        _instructions = State(initialValue: template?.instructions ?? "")
        _sections = State(initialValue: (template?.sections ?? []).map { SectionDraft(text: $0) })
    }

    private var titleText: String {
        if readOnly { return name.isEmpty ? L("Example") : name }
        if template == nil { return L("New template") }
        return L("Edit template")
    }

    private var canSave: Bool {
        !readOnly && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var instructionsText: Binding<String> {
        Binding(
            get: { instructions },
            set: { instructions = TemplateDraft.instructions($0) }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .ataBody()
                        .disabled(readOnly)
                }
                Section {
                    TextEditor(text: instructionsText)
                        .ataBody()
                        .frame(minHeight: 120)
                        .disabled(readOnly)
                    Text(verbatim: "\(TemplateDraft.instructions(instructions).count) / \(CustomTemplate.instructionLimit)")
                        .ataCaption()
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } header: {
                    Text("Instructions")
                }
                Section {
                    ForEach($sections) { $section in
                        HStack(spacing: Theme.Space.s) {
                            TextField("Heading", text: $section.text)
                                .ataBody()
                                .disabled(readOnly)
                            if !readOnly {
                                Button { move(section.id, by: -1) } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L("Move up"))
                                Button { move(section.id, by: 1) } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L("Move down"))
                                Button { sections.removeAll { $0.id == section.id } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(L("Delete"))
                            }
                        }
                    }
                    // Drag to reorder. The chevrons above do the same on a Mac, where
                    // the list has no edit mode to show a drag handle.
                    .onMove { offsets, index in
                        guard !readOnly else { return }
                        sections.move(fromOffsets: offsets, toOffset: index)
                    }
                    .onDelete { offsets in
                        guard !readOnly else { return }
                        sections.remove(atOffsets: offsets)
                    }
                    if !readOnly {
                        Button("Add a section") { sections.append(SectionDraft(text: "")) }
                    }
                } header: {
                    Text("Sections")
                }
            }
            .scrollContentBackground(Snapshots.rendering ? .hidden : .automatic)
            .navigationTitle(Text(verbatim: titleText))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readOnly ? "Done" : "Cancel") { dismiss() }
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { commit() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
        let next = index + delta
        guard sections.indices.contains(next) else { return }
        sections.move(fromOffsets: IndexSet(integer: index), toOffset: delta > 0 ? next + 1 : next)
    }

    private func commit() {
        let saved = CustomTemplate(
            id: template?.id ?? UUID(),
            name: name,
            instructions: TemplateDraft.instructions(instructions),
            sections: sections.map(\.text)
        )
        onSave(saved)
        dismiss()
    }
}
