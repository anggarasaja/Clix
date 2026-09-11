import AppKit

/// Carries out a bound action.
///
/// Everything here runs on the main queue, after the originating click has
/// already been swallowed and the event tap callback has returned.
enum ActionRunner {
    static func perform(_ action: Action) {
        switch action {
        case .block:
            break
        case .keyCombo(let combo):
            postKey(combo.keyCode, modifiers: combo.modifierFlags)
        case .launchApp(let target):
            launch(target)
        case .system(let systemAction):
            perform(systemAction)
        case .trackpadGesture(let gesture):
            guard let effect = gesture.systemEffect else { return }
            perform(effect)
        case .openURL(let string):
            open(urlString: string)
        case .shell(let command):
            runShell(command)
        }
    }

    // MARK: - Keyboard

    /// A tag written into every event Clix posts. The tap ignores mouse events
    /// only, so this exists for diagnosis rather than loop prevention.
    private static let eventSignature: Int64 = 0x434C4958  // "CLIX"

    /// Sends a keystroke as faithfully as real hardware does.
    ///
    /// Two things have to be right, and the window server's symbolic hotkeys —
    /// space switching, Spotlight, ⌃↑, Show Desktop — are unforgiving about
    /// both.
    ///
    /// The first is that a modifier must genuinely go down and come back up.
    /// A key event that merely claims in its flags that ⌃ is held is enough
    /// for an ordinary application shortcut, but the hotkey matcher wants the
    /// `flagsChanged` transitions, so the modifiers are pressed and released
    /// around the key exactly as a keyboard would.
    ///
    /// The second is that the flags have to look like hardware's. Alongside
    /// the familiar device-independent masks, a real event carries a
    /// device-dependent bit naming the side of the keyboard the modifier came
    /// from, and Apple keyboards set fn and numeric-pad on the arrow and
    /// function keys. `CGEvent` already fills all of that in; assigning
    /// `flags` wholesale wipes it out and the hotkey matcher then ignores the
    /// event. So `post` merges the modifier state into what `CGEvent` built
    /// rather than replacing it.
    static func postKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let held = modifierSequence.filter { modifiers.contains($0.flag) }

        var flags: CGEventFlags = []
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }

        for modifier in held {
            flags.formUnion(modifier.mask)
            post(modifier.keyCode, keyDown: true, flags: flags, source: source)
        }

        post(keyCode, keyDown: true, flags: flags, source: source)
        post(keyCode, keyDown: false, flags: flags, source: source)

        for modifier in held.reversed() {
            flags.subtract(modifier.mask)
            post(modifier.keyCode, keyDown: false, flags: flags, source: source)
        }
    }

    /// Pressed in this order and released in reverse, matching how a hand
    /// reaches for a combination. Each mask pairs the device-independent flag
    /// with the device-dependent bit for the left-hand key, because hardware
    /// sets both and the hotkey matcher looks for both.
    private static let modifierSequence: [(flag: NSEvent.ModifierFlags, keyCode: UInt16, mask: CGEventFlags)] = [
        (.control, 59, [.maskControl, .leftControlDevice]),
        (.option, 58, [.maskAlternate, .leftOptionDevice]),
        (.shift, 56, [.maskShift, .leftShiftDevice]),
        (.command, 55, [.maskCommand, .leftCommandDevice]),
    ]

    private static func post(
        _ keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        // `CGEvent` types a modifier key code as flagsChanged by itself, and
        // stamps the event with the fn and numeric-pad bits an Apple keyboard
        // would set for this key. Keep all of that and replace only the
        // modifier state, which is the one part we know better than it does.
        let intrinsic = event.flags.subtracting(.modifierBits)
        event.flags = intrinsic.union(flags)
        event.setIntegerValueField(.eventSourceUserData, value: eventSignature)
        event.post(tap: .cghidEventTap)
    }

    /// Media and brightness keys travel as `NSSystemDefined` events rather
    /// than ordinary key codes.
    static func postMediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let state = isDown ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | Int32(state << 8)),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - System functions

    static func perform(_ action: SystemAction) {
        switch action.implementation {
        case .combo(let keyCode, let modifiers):
            postKey(keyCode, modifiers: modifiers)
        case .media(let key):
            postMediaKey(key)
        case .custom:
            performCustom(action)
        }
    }

    private static func performCustom(_ action: SystemAction) {
        switch action {
        case .missionControl:
            // Opening the app works whatever the user has done to the ⌃↑
            // shortcut, and cannot be swallowed by a focused application.
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Mission Control.app"),
                configuration: .init()
            )
        case .launchpad:
            let launchpad = URL(fileURLWithPath: "/System/Applications/Launchpad.app")
            if FileManager.default.fileExists(atPath: launchpad.path) {
                NSWorkspace.shared.openApplication(at: launchpad, configuration: .init())
            } else {
                // Removed in macOS 26; Spotlight is the closest replacement.
                postKey(KeyCode.space, modifiers: .command)
            }
        case .sleepDisplay:
            runShell("pmset displaysleepnow")
        case .screenSaver:
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                configuration: .init()
            )
        case .doubleClick:
            postDoubleClick()
        default:
            break
        }
    }

    private static func postDoubleClick() {
        let location = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: location.x, y: screenHeight - location.y)
        let source = CGEventSource(stateID: .combinedSessionState)

        for clickState in 1...2 {
            for isDown in [true, false] {
                let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: isDown ? .leftMouseDown : .leftMouseUp,
                    mouseCursorPosition: point,
                    mouseButton: .left
                )
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Apps, URLs and commands

    private static func launch(_ target: AppTarget) {
        guard let url = target.resolvedURL else {
            log.error("Could not locate app at \(target.path, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                log.error("Launch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func open(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withScheme = trimmed.contains("://") || trimmed.hasPrefix("mailto:")
            ? trimmed
            : "https://\(trimmed)"
        guard let url = URL(string: withScheme) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func runShell(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", trimmed]
        do {
            try process.run()
        } catch {
            log.error("Command failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The modifier bits `ActionRunner` sets on the events it posts.
///
/// `CGEventFlags` names the device-independent masks but not the
/// device-dependent ones from `IOLLEvent.h`, which say which side of the
/// keyboard a modifier came from. Hardware sets a device bit alongside every
/// modifier it reports, so posted events do too.
private extension CGEventFlags {
    static let leftControlDevice = CGEventFlags(rawValue: 0x0000_0001)
    static let leftShiftDevice = CGEventFlags(rawValue: 0x0000_0002)
    static let leftCommandDevice = CGEventFlags(rawValue: 0x0000_0008)
    static let leftOptionDevice = CGEventFlags(rawValue: 0x0000_0020)

    /// Every bit describing modifier state: caps lock and the four
    /// device-independent masks, plus all eight device-dependent ones. What
    /// is left over belongs to `CGEvent` and is passed through untouched.
    static let modifierBits = CGEventFlags(rawValue: 0x001F_207F)
}
