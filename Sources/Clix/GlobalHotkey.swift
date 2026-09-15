import Carbon
import Foundation

/// A single system-wide hotkey used only as a safety net: while the menu bar
/// icon is hidden, Control-Option-Command-C is the only way back into Clix.
///
/// Registered with the Carbon event manager rather than an `NSEvent` global
/// monitor, because that needs no extra permission and keeps working while
/// Clix is neither frontmost nor visible anywhere. The hotkey is only armed
/// while the icon is hidden, so it cannot steal a meaningful key combo from
/// the user the rest of the time.
final class GlobalHotkey {
    /// The C key.
    private let keyCode = UInt32(kVK_ANSI_C)
    /// Control + Option + Command.
    private let modifiers = UInt32(controlKey | optionKey | cmdKey)
    /// A made-up signature ("CLIX") plus id 1, so the handler only answers to
    /// our own registration.
    private let signature: OSType = 0x434C4958
    private let hotKeyIDValue: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private var isRegistered = false

    /// Starts listening for the hotkey. Safe to call repeatedly; the handler
    /// is swapped but the event handler is installed only once.
    func register(onPress: @escaping () -> Void) {
        guard !isRegistered else { return }
        action = onPress

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            var handler: EventHandlerRef?
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return noErr }
                    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                    var hotKeyID = EventHotKeyID(signature: 0, id: 0)
                    GetEventParameter(
                        event,
                        EventParamName(OSType(kEventParamDirectObject)),
                        EventParamType(OSType(typeEventHotKeyID)),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )
                    if hotKeyID.signature == hotkey.signature && hotKeyID.id == hotkey.hotKeyIDValue {
                        DispatchQueue.main.async { hotkey.action?() }
                    }
                    return noErr
                },
                1,
                &eventType,
                selfPtr,
                &handler
            )
            guard status == noErr, let handler else { return }
            eventHandlerRef = handler
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyIDValue)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr
    }

    /// Stops listening. Safe to call repeatedly.
    func unregister() {
        guard isRegistered else { return }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        isRegistered = false
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
