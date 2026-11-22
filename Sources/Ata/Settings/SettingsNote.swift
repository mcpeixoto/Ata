#if os(macOS)
import AppKit
import SwiftUI

/// How many lines a settings footnote takes. The view below uses this so a
/// note longer than two lines becomes an info button instead of a paragraph.
enum SettingsNoteLayout {
    static let maxLines = 2

    /// `ataCaption()` on the Mac is 11 pt. Measuring with another font would
    /// collapse a note that still fits, or leave a third line on the form.
    static let font = NSFont.systemFont(ofSize: 11)

    static func lineCount(_ text: String, width: CGFloat) -> Int {
        guard width >= 1, !text.isEmpty else { return 1 }
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: text, attributes: [.font: font]))
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var lines = 0
        var glyph = 0
        while glyph < manager.numberOfGlyphs {
            var range = NSRange(location: 0, length: 0)
            manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            if range.length == 0 { break }
            lines += 1
            glyph = NSMaxRange(range)
        }
        return max(lines, 1)
    }

    /// A Form asks for a size before it knows the column. A zero width must
    /// not hide the text, or the first layout pass flashes the info button.
    static func collapses(_ text: String, width: CGFloat) -> Bool {
        guard width >= 80 else { return false }
        return lineCount(text, width: width) > maxLines
    }
}

/// A footnote under a setting. Two lines stay on the form. Anything longer
/// sits behind ⓘ so the pane does not grow a paragraph. `text` is already
/// localized. Pass the result of L, or a sentence already built from it.
struct SettingsNote: View {
    enum Tone { case secondary, warning }

    private let text: String
    private let tone: Tone
    @State private var open = false

    init(_ text: String, tone: Tone = .secondary) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Group {
            if SettingsNoteLayout.collapses(text, width: width) {
                infoButton
            } else {
                Text(verbatim: text)
                    .ataCaption()
                    .foregroundStyle(tone == .warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { adopt(geo.size.width) }
                    .onChange(of: geo.size.width) { _, new in adopt(new) }
            }
        }
    }

    /// The detail column is about this wide before the form has measured it,
    /// so a long note starts behind ⓘ instead of flashing a paragraph.
    @State private var width: CGFloat = 440

    private func adopt(_ new: CGFloat) {
        guard new >= 1, abs(new - width) > 1 else { return }
        width = new
    }

    private var infoButton: some View {
        Button { open = true } label: {
            Image(systemName: "info.circle")
                .ataCaption()
                .foregroundStyle(tone == .warning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: text))
        .popover(isPresented: $open) {
            Text(verbatim: text)
                .ataCaption()
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Space.m)
        }
    }
}

#endif
