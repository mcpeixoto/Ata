import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination held in the preferences and registered with the system.
///
/// Stored as `keyCode,modifiers` so it survives a change of keyboard layout:
/// the key code is the physical key, which is what the system matches on.
struct Shortcut: Equatable, Sendable {
    var keyCode: UInt16
    /// Only the four the system lets an app claim.
    var modifiers: NSEvent.ModifierFlags

    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowedModifiers)
    }

    /// Nil for an empty or malformed setting, which means "no shortcut".
    init?(_ stored: String) {
        let parts = stored.split(separator: ",")
        guard parts.count == 2, let key = UInt16(parts[0]), let raw = UInt(parts[1]) else { return nil }
        self.init(keyCode: key, modifiers: NSEvent.ModifierFlags(rawValue: raw))
    }

    var stored: String { "\(keyCode),\(modifiers.rawValue)" }

    /// A shortcut with no modifier would swallow a plain keystroke everywhere,
    /// and one with only shift is a capital letter. At least one of the other
    /// three is required.
    var isUsable: Bool {
        !modifiers.intersection([.command, .option, .control]).isEmpty
    }

    /// "⌥⌘R", in the order the menu bar writes them.
    var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + Self.name(of: keyCode)
    }

    /// The printed name of a physical key. Letters and digits are the US
    /// positions, which is what a key code means; the rest are the symbols the
    /// menu bar uses.
    static func name(of keyCode: UInt16) -> String {
        if let named = named[keyCode] { return named }
        return letters[keyCode] ?? "?"
    }

    private static let letters: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]

    private static let named: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// The one global shortcut Ata registers: start or stop recording, from
/// whatever app you are in.
///
/// Carbon's `RegisterEventHotKey` is used rather than a global event monitor
/// because it needs no Accessibility permission — a monitor would put a system
/// prompt between the user and a feature whose whole point is being quicker
/// than finding the icon.
@MainActor
enum Hotkey {
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    /// Four bytes identifying our hot key to Carbon; any value will do as long
    /// as it is ours.
    private static let signature: OSType = 0x4154_4121 // 'ATA!'

    static var current: Shortcut? {
        Pref.d.string(forKey: Pref.recordShortcut).flatMap(Shortcut.init)
    }

    /// Registers the stored shortcut, replacing whatever was registered before.
    /// Does nothing when there is none, or when it is one the system refuses.
    static func reload(action: @escaping () -> Void) {
        self.action = action
        unregister()
        guard let shortcut = current, shortcut.isUsable else { return }
        installHandler()

        var new: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers(shortcut.modifiers),
                                         EventHotKeyID(signature: signature, id: 1),
                                         GetApplicationEventTarget(), 0, &new)
        if status == noErr {
            ref = new
        } else {
            // Taken by another app or by the system. Said once, in the log: the
            // setting stays as the user typed it, and the field says it too.
            NSLog("Ata: the shortcut \(shortcut.display) is already in use (OSStatus \(status))")
        }
    }

    static func set(_ shortcut: Shortcut?, action: @escaping () -> Void) {
        Pref.d.set(shortcut?.stored ?? "", forKey: Pref.recordShortcut)
        reload(action: action)
    }

    /// Whether the system accepted the stored shortcut. False while another app
    /// holds it, so Settings can say so instead of looking like it worked.
    static var isRegistered: Bool { ref != nil }

    private static func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == Hotkey.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { Hotkey.action?() } }
            return noErr
        }, 1, &type, nil, &handler)
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var out: UInt32 = 0
        if flags.contains(.command) { out |= UInt32(cmdKey) }
        if flags.contains(.option) { out |= UInt32(optionKey) }
        if flags.contains(.control) { out |= UInt32(controlKey) }
        if flags.contains(.shift) { out |= UInt32(shiftKey) }
        return out
    }
}

/// The field in Settings that takes a key combination.
///
/// An `NSView` rather than anything in SwiftUI, because a shortcut has to be
/// caught before the menus see it: ⌘-anything never reaches `keyDown`, only
/// `performKeyEquivalent`, and a field that quietly refused every combination
/// with ⌘ in it would be useless for exactly the shortcuts people want.
struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    var onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutCatcher {
        let view = ShortcutCatcher()
        view.onCapture = { new in
            shortcut = new
            onChange(new)
        }
        return view
    }

    func updateNSView(_ view: ShortcutCatcher, context: Context) {
        view.shortcut = shortcut
    }
}

final class ShortcutCatcher: NSView {
    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    var onCapture: ((Shortcut?) -> Void)?
    private var capturing = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 22) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturing = true
    }

    override func resignFirstResponder() -> Bool {
        capturing = false
        return true
    }

    /// ⌘-combinations arrive here and nowhere else.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capturing else { return false }
        return take(event)
    }

    override func keyDown(with event: NSEvent) {
        guard capturing, take(event) else { super.keyDown(with: event); return }
    }

    /// Escape leaves the shortcut as it was; delete clears it; anything with a
    /// real modifier becomes the new one. A bare key is ignored rather than
    /// stored, since it would swallow that keystroke in every app.
    private func take(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { capturing = false; return true }                 // escape
        if event.keyCode == 51 || event.keyCode == 117 {                          // delete
            capturing = false
            shortcut = nil
            onCapture?(nil)
            return true
        }
        let candidate = Shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard candidate.isUsable else { return true }
        capturing = false
        shortcut = candidate
        onCapture?(candidate)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (capturing ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        rounded.fill()
        (capturing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        rounded.stroke()

        let text = capturing ? L("Press keys…") : (shortcut?.display ?? L("Click to set"))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: shortcut == nil ? .regular : .medium),
            .foregroundColor: shortcut == nil || capturing ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2,
                                           width: bounds.width, height: size.height),
                                withAttributes: attributes)
    }
}
