import AppKit

/// A built-in convenience function, mostly expressed as the system shortcut
/// macOS already ships for it.
enum SystemAction: String, Codable, CaseIterable, Identifiable {
    case missionControl, applicationWindows, showDesktop, launchpad, spotlight
    case spaceLeft, spaceRight, appSwitcher
    case volumeUp, volumeDown, mute
    case playPause, nextTrack, previousTrack
    case brightnessUp, brightnessDown
    case screenshotRegion, screenshotFull, screenshotUI
    case copy, paste, cut, undo, redo, selectAll, save, lookUp
    case navigateBack, navigateForward
    case newTab, closeTab, reopenTab
    case closeWindow, minimizeWindow, hideApp, quitApp
    case zoomIn, zoomOut
    case doubleClick
    case lockScreen, sleepDisplay, screenSaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .applicationWindows: return "Application Windows"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .spotlight: return "Spotlight"
        case .spaceLeft: return "Move Left a Space"
        case .spaceRight: return "Move Right a Space"
        case .appSwitcher: return "App Switcher"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next Track"
        case .previousTrack: return "Previous Track"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        case .screenshotRegion: return "Screenshot Selection"
        case .screenshotFull: return "Screenshot Whole Screen"
        case .screenshotUI: return "Screenshot Toolbar"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .cut: return "Cut"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .selectAll: return "Select All"
        case .save: return "Save"
        case .lookUp: return "Look Up"
        case .navigateBack: return "Back"
        case .navigateForward: return "Forward"
        case .newTab: return "New Tab"
        case .closeTab: return "Close Tab"
        case .reopenTab: return "Reopen Closed Tab"
        case .closeWindow: return "Close Window"
        case .minimizeWindow: return "Minimize Window"
        case .hideApp: return "Hide App"
        case .quitApp: return "Quit App"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .doubleClick: return "Double Click"
        case .lockScreen: return "Lock Screen"
        case .sleepDisplay: return "Sleep Display"
        case .screenSaver: return "Start Screen Saver"
        }
    }

    enum Group: String, CaseIterable, Identifiable {
        case desktop = "Desktop & Spaces"
        case media = "Media & Display"
        case editing = "Editing"
        case window = "Windows & Tabs"
        case mouse = "Mouse"
        case power = "Power"

        var id: String { rawValue }

        var members: [SystemAction] {
            SystemAction.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .missionControl, .applicationWindows, .showDesktop, .launchpad,
             .spotlight, .spaceLeft, .spaceRight, .appSwitcher:
            return .desktop
        case .volumeUp, .volumeDown, .mute, .playPause, .nextTrack, .previousTrack,
             .brightnessUp, .brightnessDown, .screenshotRegion, .screenshotFull, .screenshotUI:
            return .media
        case .copy, .paste, .cut, .undo, .redo, .selectAll, .save, .lookUp, .zoomIn, .zoomOut:
            return .editing
        case .navigateBack, .navigateForward, .newTab, .closeTab, .reopenTab,
             .closeWindow, .minimizeWindow, .hideApp, .quitApp:
            return .window
        case .doubleClick:
            return .mouse
        case .lockScreen, .sleepDisplay, .screenSaver:
            return .power
        }
    }

    /// Extra guidance shown under the picker for the handful of actions whose
    /// behaviour depends on the machine's own settings.
    var note: String? {
        switch self {
        case .showDesktop:
            return "Sends F11. Requires the Show Desktop shortcut to be enabled in Keyboard Settings."
        case .applicationWindows, .spaceLeft, .spaceRight:
            return "Sends the default macOS shortcut, so it follows whatever you have set in Keyboard Settings."
        case .launchpad:
            return "Launchpad was removed in macOS 26; on newer systems this opens Spotlight instead."
        default:
            return nil
        }
    }

    /// How `ActionRunner` carries the action out.
    enum Implementation {
        case combo(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
        case media(key: Int32)
        case custom
    }

    var implementation: Implementation {
        switch self {
        case .applicationWindows:  return .combo(keyCode: KeyCode.downArrow, modifiers: .control)
        case .showDesktop:         return .combo(keyCode: KeyCode.f11, modifiers: [])
        case .spotlight:           return .combo(keyCode: KeyCode.space, modifiers: .command)
        case .spaceLeft:           return .combo(keyCode: KeyCode.leftArrow, modifiers: .control)
        case .spaceRight:          return .combo(keyCode: KeyCode.rightArrow, modifiers: .control)
        case .appSwitcher:         return .combo(keyCode: KeyCode.tab, modifiers: .command)

        case .volumeUp:            return .media(key: MediaKey.soundUp)
        case .volumeDown:          return .media(key: MediaKey.soundDown)
        case .mute:                return .media(key: MediaKey.mute)
        case .playPause:           return .media(key: MediaKey.play)
        case .nextTrack:           return .media(key: MediaKey.next)
        case .previousTrack:       return .media(key: MediaKey.previous)
        case .brightnessUp:        return .media(key: MediaKey.brightnessUp)
        case .brightnessDown:      return .media(key: MediaKey.brightnessDown)

        case .screenshotRegion:    return .combo(keyCode: KeyCode.four, modifiers: [.command, .shift])
        case .screenshotFull:      return .combo(keyCode: KeyCode.three, modifiers: [.command, .shift])
        case .screenshotUI:        return .combo(keyCode: KeyCode.five, modifiers: [.command, .shift])

        case .copy:                return .combo(keyCode: KeyCode.c, modifiers: .command)
        case .paste:               return .combo(keyCode: KeyCode.v, modifiers: .command)
        case .cut:                 return .combo(keyCode: KeyCode.x, modifiers: .command)
        case .undo:                return .combo(keyCode: KeyCode.z, modifiers: .command)
        case .redo:                return .combo(keyCode: KeyCode.z, modifiers: [.command, .shift])
        case .selectAll:           return .combo(keyCode: KeyCode.a, modifiers: .command)
        case .save:                return .combo(keyCode: KeyCode.s, modifiers: .command)
        case .lookUp:              return .combo(keyCode: KeyCode.d, modifiers: [.command, .control])
        case .zoomIn:              return .combo(keyCode: KeyCode.equal, modifiers: .command)
        case .zoomOut:             return .combo(keyCode: KeyCode.minus, modifiers: .command)

        case .navigateBack:        return .combo(keyCode: KeyCode.leftBracket, modifiers: .command)
        case .navigateForward:     return .combo(keyCode: KeyCode.rightBracket, modifiers: .command)
        case .newTab:              return .combo(keyCode: KeyCode.t, modifiers: .command)
        case .closeTab:            return .combo(keyCode: KeyCode.w, modifiers: .command)
        case .reopenTab:           return .combo(keyCode: KeyCode.t, modifiers: [.command, .shift])
        case .closeWindow:         return .combo(keyCode: KeyCode.w, modifiers: [.command, .shift])
        case .minimizeWindow:      return .combo(keyCode: KeyCode.m, modifiers: .command)
        case .hideApp:             return .combo(keyCode: KeyCode.h, modifiers: .command)
        case .quitApp:             return .combo(keyCode: KeyCode.q, modifiers: .command)
        case .lockScreen:          return .combo(keyCode: KeyCode.q, modifiers: [.command, .control])

        case .missionControl, .launchpad, .sleepDisplay, .screenSaver, .doubleClick:
            return .custom
        }
    }
}

/// Virtual key codes for a US layout, as used by `CGEvent`.
enum KeyCode {
    static let a: UInt16 = 0
    static let s: UInt16 = 1
    static let d: UInt16 = 2
    static let h: UInt16 = 4
    static let z: UInt16 = 6
    static let x: UInt16 = 7
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let q: UInt16 = 12
    static let w: UInt16 = 13
    static let t: UInt16 = 17
    static let m: UInt16 = 46
    static let three: UInt16 = 20
    static let four: UInt16 = 21
    static let five: UInt16 = 23
    static let equal: UInt16 = 24
    static let minus: UInt16 = 27
    static let rightBracket: UInt16 = 30
    static let leftBracket: UInt16 = 33
    static let tab: UInt16 = 48
    static let escape: UInt16 = 53
    static let delete: UInt16 = 51
    static let space: UInt16 = 49
    static let f11: UInt16 = 103
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

/// `NX_KEYTYPE_*` constants for the system-defined media key events.
enum MediaKey {
    static let soundUp: Int32 = 0
    static let soundDown: Int32 = 1
    static let brightnessUp: Int32 = 2
    static let brightnessDown: Int32 = 3
    static let mute: Int32 = 7
    static let play: Int32 = 16
    static let next: Int32 = 17
    static let previous: Int32 = 18
}
