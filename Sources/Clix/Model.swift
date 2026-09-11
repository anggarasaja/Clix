import AppKit

// MARK: - Mouse buttons

/// Names for the CGEvent button numbers Clix can bind.
///
/// Buttons 0 and 1 (left and right) are deliberately not bindable: swallowing
/// them would leave the machine unusable if a binding misbehaved.
enum MouseButton {
    /// Buttons offered in the sidebar before any extra button is detected.
    static let standard = [2, 3, 4, 5, 6, 7]

    /// The lowest button number Clix is willing to intercept.
    static let lowestBindable = 2

    /// The button numbers Clix will accept. The upper bound is where CGEvent
    /// stops reporting distinct buttons.
    static let bindableRange = lowestBindable...31

    static func name(for number: Int) -> String {
        switch number {
        case 0: return "Left Click"
        case 1: return "Right Click"
        case 2: return "Middle Click"
        case 3: return "Button 4 (Back)"
        case 4: return "Button 5 (Forward)"
        default: return "Button \(number + 1)"
        }
    }

    static func symbol(for number: Int) -> String {
        switch number {
        case 2: return "computermouse"
        case 3: return "arrow.left.circle"
        case 4: return "arrow.right.circle"
        default: return "circle.grid.2x2"
        }
    }
}

// MARK: - Key combinations

/// A recorded keyboard shortcut: a virtual key code plus modifier flags.
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, already reduced to the device-independent set.
    var modifiers: UInt

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var displayString: String {
        KeyNames.modifierSymbols(modifierFlags) + KeyNames.label(for: keyCode)
    }
}

// MARK: - Applications

/// An application chosen by the user, stored by path with the bundle
/// identifier kept as a hint for relocated apps.
struct AppTarget: Codable, Hashable {
    var name: String
    var path: String
    var bundleIdentifier: String?

    init?(url: URL) {
        guard let bundle = Bundle(url: url) else { return nil }
        self.path = url.path
        self.bundleIdentifier = bundle.bundleIdentifier
        self.name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /// The app's current location, preferring the recorded path and falling
    /// back to a bundle-identifier lookup if the app has since moved.
    var resolvedURL: URL? {
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    var icon: NSImage? {
        guard let resolvedURL else { return nil }
        return NSWorkspace.shared.icon(forFile: resolvedURL.path)
    }
}

// MARK: - Actions

/// What a bound mouse button does when it is pressed.
enum Action: Codable, Hashable {
    /// Swallow the click and do nothing — useful for disabling a button that
    /// a mouse fires accidentally.
    case block
    case keyCombo(KeyCombo)
    case launchApp(AppTarget)
    case system(SystemAction)
    /// Do what a trackpad gesture does, so a side button can stand in for one.
    case trackpadGesture(TrackpadGesture)
    case openURL(String)
    case shell(String)

    var kind: ActionKind {
        switch self {
        case .block: return .block
        case .keyCombo: return .keyCombo
        case .launchApp: return .launchApp
        case .system: return .system
        case .trackpadGesture: return .trackpadGesture
        case .openURL: return .openURL
        case .shell: return .shell
        }
    }

    var summary: String {
        switch self {
        case .block:
            return "Do nothing"
        case .keyCombo(let combo):
            return combo.displayString
        case .launchApp(let app):
            return "Open \(app.name)"
        case .system(let action):
            return action.title
        case .trackpadGesture(let gesture):
            return gesture.title
        case .openURL(let string):
            return string.isEmpty ? "Open URL…" : string
        case .shell(let command):
            return command.isEmpty ? "Run command…" : command
        }
    }
}

/// The action families the editor offers, kept separate from `Action` so the
/// UI can switch kinds without discarding the payload of the previous one.
enum ActionKind: String, CaseIterable, Identifiable {
    case keyCombo, launchApp, system, trackpadGesture, openURL, shell, block

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyCombo: return "Keyboard Shortcut"
        case .launchApp: return "Launch App"
        case .system: return "System Function"
        case .trackpadGesture: return "Trackpad Gesture"
        case .openURL: return "Open URL"
        case .shell: return "Run Command"
        case .block: return "Do Nothing (block click)"
        }
    }

    var symbol: String {
        switch self {
        case .keyCombo: return "keyboard"
        case .launchApp: return "app.badge"
        case .system: return "switch.2"
        case .trackpadGesture: return "hand.draw"
        case .openURL: return "link"
        case .shell: return "terminal"
        case .block: return "nosign"
        }
    }
}

// MARK: - Bindings

/// When a bound mouse button carries its action out.
///
/// A trackpad gesture has no press and release of its own — it is recognised
/// once, on lift — so this only means anything for a button.
enum ActionTrigger: String, Codable, CaseIterable, Identifiable {
    case press, release

    var id: String { rawValue }

    var title: String {
        switch self {
        case .press: return "On Click"
        case .release: return "On Release"
        }
    }

    var note: String {
        switch self {
        case .press:
            return "Runs the moment the button goes down, the way a click normally feels."
        case .release:
            return "Runs when you let go, so holding the button does nothing until then. Useful for a button you often press by accident, and for anything you would rather not fire mid-drag."
        }
    }
}

/// An action together with when it runs. The click is swallowed either way,
/// so an application never sees half of one.
struct InputBinding: Codable, Hashable {
    var action: Action
    var trigger: ActionTrigger

    init(action: Action, trigger: ActionTrigger = .press) {
        self.action = action
        self.trigger = trigger
    }

    private enum CodingKeys: String, CodingKey { case action, trigger }

    init(from decoder: Decoder) throws {
        // Files written before the trigger existed store the action on its
        // own, and `Action` has no `action` case, so the key tells the two
        // shapes apart.
        if let container = try? decoder.container(keyedBy: CodingKeys.self), container.contains(.action) {
            action = try container.decode(Action.self, forKey: .action)
            trigger = try container.decodeIfPresent(ActionTrigger.self, forKey: .trigger) ?? .press
        } else {
            action = try Action(from: decoder)
            trigger = .press
        }
    }
}

// MARK: - Binding targets

/// Something a user can bind: a mouse button or a trackpad gesture.
enum BindingTarget: Hashable, Identifiable {
    case button(Int)
    case gesture(TrackpadGesture)

    var id: String {
        switch self {
        case .button(let number): return "button.\(number)"
        case .gesture(let gesture): return "gesture.\(gesture.id)"
        }
    }

    var title: String {
        switch self {
        case .button(let number): return MouseButton.name(for: number)
        case .gesture(let gesture): return gesture.title
        }
    }

    var symbol: String {
        switch self {
        case .button(let number): return MouseButton.symbol(for: number)
        case .gesture(let gesture): return gesture.symbol
        }
    }

    /// What the editor says the action replaces.
    var interceptionNote: String {
        switch self {
        case .button:
            return "The original click is swallowed and replaced by the action below."
        case .gesture:
            return "Clix can only observe the trackpad, so anything macOS already does with this gesture still happens too."
        }
    }
}
