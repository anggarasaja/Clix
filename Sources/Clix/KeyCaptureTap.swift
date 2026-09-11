import AppKit

/// A keyboard tap used only while a shortcut is being recorded.
///
/// `NSEvent` never sees combinations the system has claimed as hotkeys — ⌃←,
/// ⌃↑, ⌘Space, ⌘Tab and friends are consumed by the window server before an
/// app is offered them. Even a session tap is too late: hotkey dispatch
/// happens ahead of it. This taps at `cghidEventTap`, the point where events
/// enter the window server, which is the only placement early enough to see a
/// reserved combination — so the recorder can capture anything the hardware
/// can produce.
///
/// The tap swallows every key while it is running, so it is deliberately
/// short-lived: it stops on the first capture, when the field loses focus, and
/// after `timeout` seconds regardless, so a stuck recorder can never leave the
/// keyboard unresponsive.
final class KeyCaptureTap {
    /// Receives the key code and the modifiers held with it.
    var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    /// Called if nothing is pressed before the timeout expires.
    var onTimeout: (() -> Void)?

    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timeoutTimer: Timer?
    /// Key codes whose press we swallowed, so the matching release is
    /// swallowed too and no application sees a dangling key-up.
    private var swallowedKeys: Set<UInt16> = []

    private let timeout: TimeInterval = 8

    /// Returns `false` when the tap could not be created — usually because
    /// Accessibility access has not been granted — so the caller can fall
    /// back to ordinary `NSEvent` handling.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let capture = Unmanaged<KeyCaptureTap>.fromOpaque(refcon).takeUnretainedValue()
                return capture.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("Could not create key capture tap — Accessibility access is missing")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.stop()
            self.onTimeout?()
        }
        return true
    }

    func stop() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
        swallowedKeys.removeAll()
        isRunning = false
    }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp {
            return swallowedKeys.remove(keyCode) == nil ? Unmanaged.passUnretained(event) : nil
        }

        // A modifier on its own arrives as .flagsChanged, which is not tapped,
        // so anything reaching here is a real key.
        guard !KeyNames.modifierKeyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        let modifiers = Self.modifierFlags(from: event.flags)
        swallowedKeys.insert(keyCode)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.stop()
            self.onCapture?(keyCode, modifiers)
        }
        return nil
    }

    /// Converts tap flags to the `NSEvent` set the rest of Clix stores.
    ///
    /// `fn` is dropped: the arrow, navigation and function keys set it on most
    /// Apple hardware, which would otherwise make ⌃← record as ⌃fn← and read
    /// back differently on a keyboard that does not.
    static func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        return result
    }
}
