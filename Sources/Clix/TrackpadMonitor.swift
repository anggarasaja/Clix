import AppKit
import Combine

/// Raw trackpad contact data, from the private MultitouchSupport framework.
///
/// There is no public API for reading finger contacts system-wide, so this
/// loads the framework by hand. Everything is optional: if the framework or a
/// symbol is missing on a future macOS, gestures are simply unavailable and
/// the rest of Clix is unaffected.
///
/// Note that this only *observes*. A three-finger swipe that macOS also uses
/// for switching spaces will still switch spaces — Clix's action runs in
/// addition, not instead. Turning the system gesture off in Trackpad settings
/// is the way to get exclusive use of one.
final class TrackpadMonitor: ObservableObject {
    /// Set once the framework is loaded and at least one device was started.
    @Published private(set) var isRunning = false
    /// Set once real contact frames have arrived. Staying false while running
    /// usually means the app lacks Input Monitoring access.
    @Published private(set) var hasSeenContact = false

    var onGesture: ((TrackpadGesture) -> Void)?

    private var handle: UnsafeMutableRawPointer?
    private var devices: [MTDeviceRef] = []
    private var recognizer = GestureRecognizer()

    /// The C callback cannot capture context, so the running monitor is
    /// reachable through this.
    private static var active: TrackpadMonitor?

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }

        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            log.error("MultitouchSupport could not be loaded; trackpad gestures unavailable")
            return
        }
        self.handle = handle

        guard let createList = symbol(handle, "MTDeviceCreateList", as: MTDeviceCreateListFn.self),
              let register = symbol(handle, "MTRegisterContactFrameCallback", as: MTRegisterFn.self),
              let deviceStart = symbol(handle, "MTDeviceStart", as: MTDeviceStartFn.self),
              let list = createList()?.takeRetainedValue()
        else {
            log.error("MultitouchSupport symbols missing; trackpad gestures unavailable")
            return
        }

        Self.active = self
        for index in 0..<CFArrayGetCount(list) {
            guard let device = CFArrayGetValueAtIndex(list, index) else { continue }
            let reference = UnsafeMutableRawPointer(mutating: device)
            register(reference, contactCallback)
            deviceStart(reference, 0)
            devices.append(reference)
        }

        guard !devices.isEmpty else {
            log.notice("No multitouch devices found")
            Self.active = nil
            return
        }
        isRunning = true
        log.notice("Trackpad monitor started with \(self.devices.count, privacy: .public) device(s)")
    }

    func stop() {
        guard isRunning, let handle else { return }
        let deviceStop = symbol(handle, "MTDeviceStop", as: MTDeviceStopFn.self)
        let unregister = symbol(handle, "MTUnregisterContactFrameCallback", as: MTRegisterFn.self)
        for device in devices {
            unregister?(device, contactCallback)
            deviceStop?(device)
        }
        devices.removeAll()
        recognizer.reset()
        isRunning = false
        hasSeenContact = false
        Self.active = nil
    }

    deinit { stop() }

    // MARK: - Frames

    /// Called on MultitouchSupport's own thread.
    fileprivate func handleFrame(touches: UnsafeMutablePointer<MTTouch>?, count: Int32, timestamp: Double) {
        let fingers = (0..<Int(count)).compactMap { index -> MTTouch? in
            guard let touch = touches?[index] else { return nil }
            // State 4 is a settled contact; the transient states either side
            // of it make the finger count flicker.
            return touch.state == 4 ? touch : nil
        }

        let gesture = recognizer.consume(fingers: fingers, timestamp: timestamp)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.hasSeenContact, count > 0 { self.hasSeenContact = true }
            if let gesture { self.onGesture?(gesture) }
        }
    }

    private func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}

// MARK: - Recognition

/// Turns a stream of contact frames into discrete gestures.
///
/// A gesture is one "session": the span from three or more fingers landing to
/// the last of them lifting. The session is classified once, on lift, so a
/// swipe cannot also register as a tap.
private struct GestureRecognizer {
    private var startTime: Double = 0
    private var startCentroid = CGPoint.zero
    private var lastCentroid = CGPoint.zero
    /// How many frames each finger count was seen for during this session.
    /// The count seen most often is the gesture's, which keeps a thumb that
    /// brushes the pad for a frame or two from turning a four-finger swipe
    /// into a five-finger one nothing is bound to.
    private var framesPerCount: [Int: Int] = [:]
    /// The most fingers down so far, used to tell a hand still landing from
    /// one that has settled.
    private var settledFingers = 0
    private var isTracking = false

    /// Below this many fingers there is nothing Clix binds, and two-finger
    /// contact is far too easy to trigger by resting a hand.
    private let minimumFingers = 3
    /// A contact longer than this is a drag or a rest, not a tap.
    private let tapDuration: Double = 0.35
    /// Normalised units — the trackpad is 1.0 wide however large it is.
    private let tapTolerance: CGFloat = 0.04
    private let swipeThreshold: CGFloat = 0.10

    mutating func reset() {
        isTracking = false
        framesPerCount = [:]
        settledFingers = 0
    }

    mutating func consume(fingers: [MTTouch], timestamp: Double) -> TrackpadGesture? {
        let centroid = Self.centroid(of: fingers)

        if fingers.count >= minimumFingers {
            if !isTracking {
                isTracking = true
                framesPerCount = [:]
                settledFingers = 0
            }
            framesPerCount[fingers.count, default: 0] += 1

            // Fingers rarely land together, and while they are still arriving
            // the centroid moves for reasons that are not a swipe. Measuring
            // restarts each time another one lands, and stops being updated
            // once they start lifting again, so a gesture is measured across
            // full contact only.
            if fingers.count > settledFingers {
                settledFingers = fingers.count
                startTime = timestamp
                startCentroid = centroid
            }
            if fingers.count == settledFingers { lastCentroid = centroid }
            return nil
        }

        // Fingers have lifted (or dropped below the threshold): classify.
        guard isTracking else { return nil }
        isTracking = false
        let fingerCount = Self.dominantCount(in: framesPerCount)
        framesPerCount = [:]
        settledFingers = 0

        let duration = timestamp - startTime
        let dx = lastCentroid.x - startCentroid.x
        let dy = lastCentroid.y - startCentroid.y

        if abs(dx) >= swipeThreshold, abs(dx) > abs(dy) {
            return TrackpadGesture(fingers: fingerCount, motion: dx > 0 ? .right : .left)
        }
        if abs(dy) >= swipeThreshold, abs(dy) > abs(dx) {
            // Normalised Y grows towards the far edge of the trackpad.
            return TrackpadGesture(fingers: fingerCount, motion: dy > 0 ? .up : .down)
        }
        if duration <= tapDuration, abs(dx) < tapTolerance, abs(dy) < tapTolerance {
            return TrackpadGesture(fingers: fingerCount, motion: .tap)
        }
        return nil
    }

    /// The finger count seen for the most frames, preferring the larger
    /// count when two are seen equally often.
    private static func dominantCount(in frames: [Int: Int]) -> Int {
        frames.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 0
    }

    private static func centroid(of fingers: [MTTouch]) -> CGPoint {
        guard !fingers.isEmpty else { return .zero }
        let sum = fingers.reduce(into: CGPoint.zero) { total, touch in
            total.x += CGFloat(touch.normalized.position.x)
            total.y += CGFloat(touch.normalized.position.y)
        }
        return CGPoint(x: sum.x / CGFloat(fingers.count), y: sum.y / CGFloat(fingers.count))
    }
}

// MARK: - MultitouchSupport bridging

typealias MTDeviceRef = UnsafeMutableRawPointer

struct MTPoint {
    var x: Float
    var y: Float
}

struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// Layout must match MultitouchSupport's own `MTTouch`.
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var fingerID: Int32
    var handID: Int32
    var normalized: MTVector
    var size: Float
    var pressure: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absolute: MTVector
    var unknown1: Int32
    var unknown2: Int32
    var density: Float
}

private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
private typealias MTRegisterFn = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
private typealias MTDeviceStartFn = @convention(c) (MTDeviceRef, Int32) -> Void
private typealias MTDeviceStopFn = @convention(c) (MTDeviceRef) -> Void

private let contactCallback: MTContactCallback = { _, touches, count, timestamp, _ in
    let typed = touches?.assumingMemoryBound(to: MTTouch.self)
    TrackpadMonitor.activeMonitor?.handleFrame(touches: typed, count: count, timestamp: timestamp)
    return 0
}

extension TrackpadMonitor {
    /// Bridges the C callback back to the running instance.
    fileprivate static var activeMonitor: TrackpadMonitor? { active }
}
