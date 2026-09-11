import Foundation

/// A trackpad gesture Clix can bind: a finger count plus a motion.
struct TrackpadGesture: Codable, Hashable, Identifiable {
    enum Motion: String, Codable, CaseIterable {
        case tap, left, right, up, down
    }

    var fingers: Int
    var motion: Motion

    /// Stable string form, used as the key when bindings are written out.
    var id: String { "\(fingers)-\(motion.rawValue)" }

    init(fingers: Int, motion: Motion) {
        self.fingers = fingers
        self.motion = motion
    }

    init?(id: String) {
        let parts = id.split(separator: "-")
        guard parts.count == 2,
              let fingers = Int(parts[0]),
              let motion = Motion(rawValue: String(parts[1]))
        else { return nil }
        self.init(fingers: fingers, motion: motion)
    }

    /// The gestures offered in the UI. Five fingers is tap only — a five
    /// finger swipe is not something a hand does comfortably.
    static let supported: [TrackpadGesture] = {
        var result: [TrackpadGesture] = []
        for fingers in [3, 4] {
            for motion in Motion.allCases {
                result.append(TrackpadGesture(fingers: fingers, motion: motion))
            }
        }
        result.append(TrackpadGesture(fingers: 5, motion: .tap))
        return result
    }()

    /// What macOS does for this gesture out of the box.
    ///
    /// This is how a mouse button bound to a gesture is carried out. macOS has
    /// no public way to inject finger contacts, so Clix reproduces the
    /// gesture's *effect* rather than the gesture itself — which is the part
    /// anyone binding a side button actually wants.
    ///
    /// Swiping is content-relative: pushing the desktop left with four fingers
    /// brings the space on the right into view.
    var systemEffect: SystemAction? {
        switch motion {
        case .left: return fingers >= 3 ? .spaceRight : nil
        case .right: return fingers >= 3 ? .spaceLeft : nil
        case .up: return fingers >= 3 ? .missionControl : nil
        case .down: return fingers >= 3 ? .applicationWindows : nil
        case .tap: return fingers == 3 ? .lookUp : nil
        }
    }

    /// The gestures a mouse button can stand in for: everything macOS assigns
    /// a default to. A four and five finger tap do nothing by default, so
    /// there is nothing to mimic.
    static let performable: [TrackpadGesture] = supported.filter { $0.systemEffect != nil }

    var title: String {
        let count = ["", "One", "Two", "Three", "Four", "Five"]
        let name = fingers < count.count ? count[fingers] : "\(fingers)"
        switch motion {
        case .tap: return "\(name)-Finger Tap"
        case .left: return "\(name)-Finger Swipe Left"
        case .right: return "\(name)-Finger Swipe Right"
        case .up: return "\(name)-Finger Swipe Up"
        case .down: return "\(name)-Finger Swipe Down"
        }
    }

    var symbol: String {
        switch motion {
        case .tap: return "hand.tap"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        }
    }

    /// Gestures macOS itself may already use, which Clix cannot take away from
    /// it — its action runs as well as the system's.
    var systemConflict: String? {
        switch (fingers, motion) {
        case (3, .left), (3, .right), (4, .left), (4, .right):
            return "macOS may also use this to switch spaces. Turn that off in Trackpad settings for exclusive use."
        case (3, .up), (4, .up):
            return "macOS may also use this for Mission Control. Turn that off in Trackpad settings for exclusive use."
        case (3, .down), (4, .down):
            return "macOS may also use this for App Exposé. Turn that off in Trackpad settings for exclusive use."
        case (3, .tap):
            return "May conflict with Look Up if three-finger tap is enabled in Trackpad settings."
        default:
            return nil
        }
    }
}
