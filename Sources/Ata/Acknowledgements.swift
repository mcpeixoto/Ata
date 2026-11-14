import SwiftUI

/// The bundled NOTICE. Nil when the file was not copied into the app, so the
/// settings row stays hidden rather than opening an empty sheet.
enum Acknowledgements {
    /// Settings reads this from `body`. The file does not change while Ata is open.
    private static var cachedForMain: String??

    static func text(in bundle: Bundle = .main) -> String? {
        if bundle === Bundle.main, let cached = cachedForMain { return cached }
        let value = load(bundle)
        if bundle === Bundle.main { cachedForMain = value }
        return value
    }

    private static func load(_ bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: "NOTICE", withExtension: nil)
            ?? bundle.url(forResource: "NOTICE", withExtension: "txt") else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

/// The NOTICE file, scrollable and selectable. LAME is LGPL and is linked in.
struct AcknowledgementsView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(verbatim: text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("Acknowledgements")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}
