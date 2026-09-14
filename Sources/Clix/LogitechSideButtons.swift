import AppKit
import Combine
import CoreGraphics
import IOKit
import IOKit.hid

/// Takes the side buttons of a Logitech mouse away from its firmware, so they
/// report the moment they are pressed.
///
/// Mice without a tilt wheel — the M650 and the Lift among them — offer
/// horizontal scrolling by holding a side button and turning the wheel. To tell
/// a click apart from the start of such a scroll, the firmware *withholds* the
/// press: nothing at all is sent until the button comes back up, and then the
/// press and the release arrive together, milliseconds apart. No event tap can
/// undo that, because at press time there is no event to see.
///
/// HID++ has a way out. `setCidReporting` can divert a control, which stops the
/// device reporting it as an ordinary click and sends it to the host as a
/// notification instead — immediately, because the firmware is no longer
/// waiting to find out whether a scroll is coming. Clix then decides what the
/// press means, and the hold-to-scroll gesture on those buttons goes away.
///
/// The diversion is deliberately not persisted to the device: it lives only
/// while Clix holds it, and unplugging the receiver or power-cycling the mouse
/// puts everything back.
final class LogitechSideButtons: ObservableObject {
    /// A mouse that buffers its side buttons is connected and can be taken over.
    @Published private(set) var deviceName: String?
    /// The diversion is in force right now.
    @Published private(set) var isActive = false
    /// Why it is not, when it is not.
    @Published private(set) var problem: String?
    /// The only way to this mouse is Bluetooth, and macOS will not let Clix
    /// open it without Input Monitoring. Distinct from `problem` because the
    /// user can actually do something about this one.
    @Published private(set) var needsInputMonitoring = false

    /// Called once a diverted button goes down and again when it comes up.
    var onButton: (Int, ActionTrigger) -> Void = { _, _ in }
    /// Called for every diverted press, so the "click a button to identify it"
    /// flow keeps working for buttons the tap can no longer see.
    var onButtonSeen: (Int) -> Void = { _ in }
    /// Whether Clix has something to do with this button. An unbound one is
    /// posted back as a real click, so taking it over costs the user nothing.
    var isBound: (Int) -> Bool = { _ in false }

    private let work = DispatchQueue(label: "com.digigara.Clix.logitech")
    private var link: HIDPPLink?
    private var controlsFeature: UInt8?
    /// The controls Clix diverted, so exactly those can be handed back.
    private var diverted: [HIDPP.Control] = []
    /// Which diverted controls were down at the last notification, so the
    /// press-and-release edges can be worked out from the device's list of
    /// what is currently held.
    private var held: Set<HIDPP.Control> = []
    private var wantsActive = false
    private var hotplug: IOHIDManager?
    /// Buttons whose press was posted back as an ordinary click, so the
    /// matching release is posted too. Main thread only.
    private var passedThrough: Set<Int> = []
    /// Counts hotplug bursts so only the newest one rebuilds the link.
    private var rebuildGeneration = 0
    /// How long to wait before trying a failed connection again, and whether an
    /// attempt is already booked. A mouse is not always ready the instant it is
    /// announced — switching from the receiver to Bluetooth takes a moment, and
    /// a sleeping Bluetooth mouse answers nothing at all until it is moved —
    /// so a single failed attempt must not be the end of it.
    private var retryDelay: TimeInterval = 1
    private var retryBooked = false
    /// The system prompt is only worth showing once a run; after that it is
    /// silent and the user has to go to Settings themselves.
    private var hasAskedForInputMonitoring = false
    /// IOKit reports every already-attached device when the watch is set up.
    /// That first round says nothing new — `scan` is already looking — so it is
    /// ignored rather than tearing a working link down and building it again.
    private var hotplugSettlesAt = Date.distantPast

    init() {
        watchForDeviceChanges()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Switching on and off

    /// Looks for a mouse without changing anything, so the setting can be
    /// offered before it is switched on.
    func scan() {
        work.async { [weak self] in
            guard let self else { return }
            if self.link == nil { self.connect() }
        }
    }

    /// Turns the takeover on or off. Returns immediately; the work happens off
    /// the main thread and the published state catches up.
    func setEnabled(_ enabled: Bool) {
        work.async { [weak self] in
            guard let self else { return }
            self.wantsActive = enabled
            if enabled {
                self.activate()
            } else {
                self.deactivate()
                if self.link == nil { self.connect() }
            }
        }
    }

    /// Hands the buttons back and waits for it, for use on the way out of the
    /// app where a queued block would never run.
    func shutDown() {
        work.sync {
            wantsActive = false
            deactivate()
        }
    }

    // MARK: - The work

    private func activate() {
        guard wantsActive else { return }
        if link == nil { connect() }
        guard let link, let feature = controlsFeature else { return }

        var taken: [HIDPP.Control] = []
        for control in divertableControls(link: link, feature: feature) {
            if setDivert(control, on: true, link: link, feature: feature) { taken.append(control) }
        }
        diverted = taken
        held = []

        let succeeded = !taken.isEmpty
        publish { [weak self] in
            self?.isActive = succeeded
            self?.problem = succeeded ? nil : "This mouse would not hand over its side buttons."
        }
        if succeeded {
            log.notice("Diverted \(taken.count) side button(s) on \(link.productName, privacy: .public)")
        }
    }

    private func deactivate() {
        if let link, let feature = controlsFeature {
            for control in diverted { _ = setDivert(control, on: false, link: link, feature: feature) }
        }
        diverted = []
        held = []
        publish { [weak self] in
            self?.isActive = false
            self?.problem = nil
        }
    }

    /// Opens a link and works out what is on the other end.
    private func connect() {
        let candidates = HIDPPLink.candidates()
        if candidates.isEmpty { log.notice("HID++: no Logitech node with a vendor collection") }
        var blockedOnPermission = false
        for candidate in candidates {
            if candidate.transport.needsInputMonitoring, !hasInputMonitoring() {
                blockedOnPermission = true
                continue
            }
            guard let link = HIDPPLink(device: candidate.device, transport: candidate.transport) else {
                // A refused open on the mouse node is almost always the
                // permission, whatever the access check claimed.
                if candidate.transport.needsInputMonitoring { blockedOnPermission = true }
                continue
            }
            // Notifications arrive on the link's thread; hop onto the work
            // queue so `held` and `controlsFeature` have a single owner.
            link.onNotification = { [weak self] payload in
                self?.work.async { self?.handle(payload) }
            }
            guard link.locateDevice() else {
                log.notice("HID++: nothing answered on the \(candidate.transport.description, privacy: .public) node")
                link.close()
                continue
            }
            guard let feature = link.index(of: .reprogControls) else {
                log.notice("HID++: \(link.productName, privacy: .public) has no reprogrammable controls feature")
                link.close()
                continue
            }
            self.link = link
            self.controlsFeature = feature
            self.retryDelay = 1
            let name = link.productName
            publish { [weak self] in
                self?.deviceName = name
                self?.problem = nil
                self?.needsInputMonitoring = false
            }
            return
        }
        publish { [weak self] in
            self?.deviceName = nil
            self?.needsInputMonitoring = blockedOnPermission
            self?.problem = blockedOnPermission ? nil : "No Logitech mouse found."
        }
        scheduleRetry()
    }

    /// Whether macOS will let Clix open a pointing device, asking once if the
    /// question has never been put to the user.
    private func hasInputMonitoring() -> Bool {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { return true }
        if !hasAskedForInputMonitoring {
            hasAskedForInputMonitoring = true
            // Only prompts while the user has yet to decide; once denied it
            // returns quietly and Settings is the only way back.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        return false
    }

    /// Opens Privacy & Security at the Input Monitoring list.
    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// Books another attempt, backing off so a mouse that never answers costs
    /// almost nothing. Pointless when no Logitech device is attached at all: a
    /// hotplug callback will start things off when one appears.
    private func scheduleRetry() {
        guard !retryBooked, !HIDPPLink.candidates().isEmpty else { return }
        retryBooked = true
        log.notice("HID++: no link yet, trying again in \(self.retryDelay, privacy: .public)s")
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 10)
        work.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryBooked = false
            guard self.link == nil else { return }
            if self.wantsActive { self.activate() } else { self.connect() }
        }
    }

    private func disconnect() {
        link?.close()
        link = nil
        controlsFeature = nil
        diverted = []
        held = []
        publish { [weak self] in
            self?.deviceName = nil
            self?.isActive = false
        }
    }

    /// The navigation controls this device is willing to hand over. Asking
    /// rather than assuming keeps this working on the other mice in the family,
    /// which use different control ids for the same two buttons.
    private func divertableControls(link: HIDPPLink, feature: UInt8) -> [HIDPP.Control] {
        guard let count = link.request(device: link.deviceIndex, feature: feature, function: 0)?.first else { return [] }
        var controls: [HIDPP.Control] = []
        for slot in 0..<Int(count) {
            guard let info = link.request(device: link.deviceIndex, feature: feature,
                                          function: 1, params: [UInt8(slot)]),
                  info.count >= 5 else { continue }
            let id = UInt16(info[0]) << 8 | UInt16(info[1])
            guard let control = HIDPP.Control(rawValue: id),
                  info[4] & HIDPP.ControlFlag.divertable != 0 else { continue }
            controls.append(control)
        }
        return controls
    }

    /// `setCidReporting`: the divert bit only takes effect when its validity
    /// bit is set alongside it, which is also how the flag is cleared again.
    private func setDivert(_ control: HIDPP.Control, on: Bool, link: HIDPPLink, feature: UInt8) -> Bool {
        let flags: UInt8 = on ? 0x03 : 0x02
        let params: [UInt8] = [UInt8(control.rawValue >> 8), UInt8(control.rawValue & 0xFF), flags, 0, 0, 0]
        return link.request(device: link.deviceIndex, feature: feature, function: 3, params: params) != nil
    }

    // MARK: - Incoming presses

    private func handle(_ payload: [UInt8]) {
        // A device coming back from sleep loses the diversion, so put it back.
        if payload.count >= 2, payload[1] == 0x41 {
            if wantsActive { activate() }
            return
        }

        guard let feature = controlsFeature,
              payload.count >= 3,
              payload[1] == feature,
              payload[2] == 0x00 else { return }   // function 0 with no software id: the event

        // The device reports everything currently held, not the change, so the
        // edges come from comparing against what was held a moment ago.
        var pressed: Set<HIDPP.Control> = []
        for offset in stride(from: 3, to: min(11, payload.count - 1), by: 2) {
            let id = UInt16(payload[offset]) << 8 | UInt16(payload[offset + 1])
            if let control = HIDPP.Control(rawValue: id) { pressed.insert(control) }
        }

        let wentDown = pressed.subtracting(held)
        let cameUp = held.subtracting(pressed)
        held = pressed

        for control in wentDown { deliver(control, .press) }
        for control in cameUp { deliver(control, .release) }
    }

    private func deliver(_ control: HIDPP.Control, _ trigger: ActionTrigger) {
        let button = control.buttonNumber
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if trigger == .press {
                self.onButtonSeen(button)
                // Nothing bound: put the click back so the button still does
                // what it always did, just without the wait. The decision is
                // remembered, so a binding added while the button is held
                // cannot swallow the release and leave the click stuck down.
                if !self.isBound(button) {
                    self.passedThrough.insert(button)
                    Self.postClick(button: button, down: true)
                    return
                }
            } else if self.passedThrough.remove(button) != nil {
                Self.postClick(button: button, down: false)
                return
            }
            self.onButton(button, trigger)
        }
    }

    /// Posts a real click for a button the device is no longer reporting itself.
    private static func postClick(button: Int, down: Bool) {
        guard let location = CGEvent(source: nil)?.location,
              let event = CGEvent(mouseEventSource: nil,
                                  mouseType: down ? .otherMouseDown : .otherMouseUp,
                                  mouseCursorPosition: location,
                                  mouseButton: .center) else { return }
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keeping up with the hardware

    /// Receivers get unplugged and mice get switched off. Either way the link
    /// has to be rebuilt before the diversion can be put back.
    private func watchForDeviceChanges() {
        hotplugSettlesAt = Date().addingTimeInterval(1.0)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<LogitechSideButtons>.fromOpaque(context).takeUnretainedValue().hardwareChanged(appeared: true)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<LogitechSideButtons>.fromOpaque(context).takeUnretainedValue().hardwareChanged(appeared: false)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hotplug = manager
    }

    /// One receiver arrives as several HID nodes, so a single replug lands here
    /// repeatedly. The rebuild is deferred and coalesced: only the last change
    /// of a burst does the work, which also gives the device time to finish
    /// arriving before it is asked anything.
    private func hardwareChanged(appeared: Bool) {
        guard Date() >= hotplugSettlesAt else { return }
        work.async { [weak self] in
            guard let self else { return }
            self.rebuildGeneration &+= 1
            self.retryDelay = 1
            let generation = self.rebuildGeneration
            self.work.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, generation == self.rebuildGeneration else { return }
                self.disconnect()
                if self.wantsActive { self.activate() } else { self.connect() }
            }
        }
    }

    @objc private func systemDidWake() {
        work.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.disconnect()
            if self.wantsActive { self.activate() } else { self.connect() }
        }
    }

    private func publish(_ change: @escaping () -> Void) {
        DispatchQueue.main.async(execute: change)
    }
}
