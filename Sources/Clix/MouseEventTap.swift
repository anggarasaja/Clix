import AppKit
import Combine

/// A CGEvent tap over the extra mouse buttons (everything except left and right).
///
/// The tap runs on the main run loop. Its callback stays cheap: it decides
/// whether the click is bound and, if so, swallows it and hands the button
/// number to `onButtonDown` asynchronously, so no action runs while the event
/// system is waiting on us.
final class MouseEventTap: ObservableObject {
    /// Returns `true` when the button is bound and its click should be swallowed.
    var shouldHandle: (Int) -> Bool = { _ in false }
    /// Called on the main queue once the click has been consumed: once as the
    /// button goes down, and again when it comes back up. Which of the two a
    /// binding acts on is the binding's business, not the tap's.
    var onButton: (Int, ActionTrigger) -> Void = { _, _ in }
    /// Called for every extra-button press, bound or not, so the UI can offer
    /// "click a button to identify it".
    var onButtonSeen: (Int) -> Void = { _ in }

    @Published private(set) var isRunning = false
    /// Where the running tap ended up, so the UI can say when Clix had to
    /// settle for the session tap.
    @Published private(set) var placement: TapPlacement?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Buttons whose down event we swallowed, so the matching up and any drag
    /// in between are swallowed too and applications never see a half click.
    private var swallowedButtons: Set<Int> = []

    enum StartError: LocalizedError {
        case accessibilityDenied

        var errorDescription: String? {
            "Clix could not create an event tap. Grant Accessibility access and try again."
        }
    }

    func start() throws {
        guard !isRunning else { return }

        let mask = (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)

        // Placement decides more than where the click is swallowed. At the
        // session tap the window server has already seen the button go down
        // and treats it as a drag in progress, so it holds back what the
        // action does — a space switch waits for the button to come up, which
        // looks exactly like firing on release. Filtered at the HID tap the
        // press never reaches the window server, and the action lands at
        // once. The session tap stays as a fallback for the case where the
        // HID placement is refused.
        var created: (tap: CFMachPort, placement: TapPlacement)?
        for placement in TapPlacement.allCases {
            guard let tap = CGEvent.tapCreate(
                tap: placement.location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { proxy, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<MouseEventTap>.fromOpaque(refcon).takeUnretainedValue()
                    return tap.handle(proxy: proxy, type: type, event: event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { continue }
            created = (tap, placement)
            break
        }

        guard let created else { throw StartError.accessibilityDenied }
        let tap = created.tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        placement = created.placement
        isRunning = true
        log.notice("Event tap started at the \(created.placement.rawValue, privacy: .public) tap")
    }

    /// Where the tap sits, in the order Clix wants it.
    enum TapPlacement: String, CaseIterable {
        case hid, session

        var location: CGEventTapLocation {
            switch self {
            case .hid: return .cghidEventTap
            case .session: return .cgSessionEventTap
            }
        }
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
        swallowedButtons.removeAll()
        placement = nil
        isRunning = false
        log.notice("Event tap stopped")
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or when the user
        // changes the input setup. Re-enabling is all that is needed.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard button >= MouseButton.lowestBindable else { return Unmanaged.passUnretained(event) }

        switch type {
        case .otherMouseDown:
            DispatchQueue.main.async { [onButtonSeen] in onButtonSeen(button) }
            guard shouldHandle(button) else { return Unmanaged.passUnretained(event) }
            swallowedButtons.insert(button)
            DispatchQueue.main.async { [onButton] in onButton(button, .press) }
            return nil

        case .otherMouseUp:
            guard swallowedButtons.remove(button) != nil else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { [onButton] in onButton(button, .release) }
            return nil

        case .otherMouseDragged:
            return swallowedButtons.contains(button) ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
