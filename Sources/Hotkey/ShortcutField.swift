import SwiftUI
import AppKit

/// A click-to-record keyboard-shortcut field. Click, then press the combo.
struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: Shortcut

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = { shortcut = $0 }
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.shortcut = shortcut
        view.needsDisplay = true
    }

    final class RecorderView: NSView {
        var shortcut: Shortcut = .defaultToggle
        var onCapture: ((Shortcut) -> Void)?
        private var recording = false

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 24) }

        override func draw(_ dirtyRect: NSRect) {
            let bg = recording ? NSColor.controlAccentColor.withAlphaComponent(0.2)
                               : NSColor.controlBackgroundColor
            bg.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                    xRadius: 6, yRadius: 6)
            path.fill()
            NSColor.separatorColor.setStroke(); path.stroke()

            let text = recording ? "Press keys…" : shortcut.display
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(
                at: NSPoint(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2),
                withAttributes: attrs)
        }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
            needsDisplay = true
        }

        override func keyDown(with event: NSEvent) {
            if !capture(event) { super.keyDown(with: event) }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            recording ? capture(event) : super.performKeyEquivalent(with: event)
        }

        private func capture(_ event: NSEvent) -> Bool {
            guard recording else { return false }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else { return true } // require a modifier
            let key = (event.charactersIgnoringModifiers ?? "").uppercased()
            let new = Shortcut(keyCode: UInt32(event.keyCode),
                               modifiers: mods.rawValue,
                               display: Self.symbols(mods) + key)
            shortcut = new
            onCapture?(new)
            recording = false
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return true
        }

        static func symbols(_ mods: NSEvent.ModifierFlags) -> String {
            var s = ""
            if mods.contains(.control) { s += "⌃" }
            if mods.contains(.option)  { s += "⌥" }
            if mods.contains(.shift)   { s += "⇧" }
            if mods.contains(.command) { s += "⌘" }
            return s
        }
    }
}
