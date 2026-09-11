import AppKit
import SwiftUI

/// A click-to-record field for a keyboard shortcut.
///
/// While recording, the view takes every key event, including combinations
/// like ⌘Q that would otherwise be handled as menu equivalents.
final class ShortcutRecorderView: NSView {
    var combo: KeyCombo? { didSet { needsDisplay = true } }
    var onCapture: ((KeyCombo?) -> Void)?
    /// True once a recording attempt has had to fall back to `NSEvent`, which
    /// cannot see combinations macOS reserves for itself.
    private(set) var isDegraded = false
    var onDegraded: (() -> Void)?

    /// Runs ahead of the system's hotkey dispatch so combinations macOS has
    /// claimed for itself — ⌃←, ⌃↑, ⌘Space, ⌘Tab — can still be recorded.
    private let captureTap = KeyCaptureTap()

    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            if isRecording { beginCapture() } else { captureTap.stop() }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { isRecording = false }
    }

    deinit { captureTap.stop() }

    private func beginCapture() {
        captureTap.onCapture = { [weak self] keyCode, modifiers in
            self?.finish(keyCode: keyCode, modifiers: modifiers)
        }
        captureTap.onTimeout = { [weak self] in
            self?.endRecording()
        }
        // Without Accessibility access the tap cannot be created; ordinary
        // NSEvent handling still covers everything except system hotkeys.
        if !captureTap.start() {
            log.notice("Recording without an event tap; system shortcuts cannot be captured")
            isDegraded = true
            onDegraded?()
        }
    }

    // MARK: - Key handling

    /// The `NSEvent` path, used only when the capture tap is unavailable.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, !captureTap.isRunning else { return false }
        finish(keyCode: event.keyCode, modifiers: event.modifierFlags)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, !captureTap.isRunning else {
            super.keyDown(with: event)
            return
        }
        finish(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    private func finish(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard !KeyNames.modifierKeyCodes.contains(keyCode) else { return }

        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let cleaned = modifiers.intersection(.deviceIndependentFlagsMask).intersection(relevant)

        // Escape and Delete keep their plain meanings — cancel and clear — but
        // stay recordable in combination, so ⌘⎋ and ⌥⌫ can still be bound.
        if cleaned.isEmpty, keyCode == KeyCode.escape {
            endRecording()
            return
        }
        if cleaned.isEmpty, keyCode == KeyCode.delete {
            combo = nil
            onCapture?(nil)
            endRecording()
            return
        }

        let captured = KeyCombo(keyCode: keyCode, modifiers: cleaned.rawValue)
        combo = captured
        onCapture?(captured)
        endRecording()
    }

    private func endRecording() {
        isRecording = false
        window?.makeFirstResponder(nil)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)

        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                     : NSColor.controlBackgroundColor).setFill()
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = isDegraded ? "Press a shortcut (limited)…" : "Press a shortcut…"
            color = .controlAccentColor
        } else if let combo {
            text = combo.displayString
            color = .labelColor
        } else {
            text = "Click to record"
            color = .secondaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isRecording || combo == nil ? .regular : .medium),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                y: (bounds.height - size.height) / 2))
    }
}

/// SwiftUI wrapper around `ShortcutRecorderView`.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo?
    /// Set when the recorder could not install its tap, so the editor can
    /// explain why a system shortcut refused to record.
    @Binding var isDegraded: Bool

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.combo = combo
        view.onCapture = { context.coordinator.captured($0) }
        view.onDegraded = { context.coordinator.degraded() }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        context.coordinator.parent = self
        if view.combo != combo { view.combo = combo }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: ShortcutRecorder

        init(parent: ShortcutRecorder) { self.parent = parent }

        func captured(_ combo: KeyCombo?) { parent.combo = combo }

        func degraded() { parent.isDegraded = true }
    }
}
