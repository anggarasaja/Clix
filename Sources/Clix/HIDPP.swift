import Foundation
import IOKit
import IOKit.hid

/// HID++ 2.0 — the protocol Logitech devices speak over a vendor-specific HID
/// collection that sits alongside the ordinary mouse one.
///
/// Two transports carry the same protocol, and Clix takes whichever is there:
///
///   * a Bolt or Unifying receiver on USB — vendor usage page `0xFF00`, a short
///     report `0x10` and a long report `0x11`, with paired devices addressed
///     `1...6`;
///   * the mouse paired straight to Bluetooth — vendor usage page `0xFF43`,
///     the long report only, addressed `0xFF`.
///
/// Every request names a feature and a function and gets exactly one reply.
/// Feature *indices* are assigned per device and have to be looked up by
/// feature *id* through the root feature, which is always index 0.
enum HIDPP {
    static let shortReport: CFIndex = 0x10
    static let longReport: CFIndex = 0x11

    /// Stamped into the low nibble of every request so replies meant for other
    /// software — Logi Options+, say — are not mistaken for ours.
    static let softwareID: UInt8 = 0x0A

    /// Feature ids Clix asks for by name.
    enum Feature: UInt16 {
        case root = 0x0000
        /// Reprogrammable controls v4: what the buttons are and how they report.
        case reprogControls = 0x1B04
    }

    /// Control ids for the navigation buttons. These are the ones a mouse with
    /// no tilt wheel presses into service as a horizontal-scroll modifier.
    enum Control: UInt16, CaseIterable {
        case back = 0x0053
        case forward = 0x0054
        case fastBack = 0x0055
        case fastForward = 0x0056

        /// The CGEvent button number the control stands in for, so a diverted
        /// press can join the same pipeline as a tapped one.
        var buttonNumber: Int {
            switch self {
            case .back, .fastBack: return 3
            case .forward, .fastForward: return 4
            }
        }
    }

    /// `getCtrlIdInfo` flag bits. Only the two Clix acts on are named.
    enum ControlFlag {
        /// The device is willing to hand this button to the host instead of
        /// reporting it as an ordinary click.
        static let divertable: UInt8 = 0x20
    }
}

/// One open HID++ conversation.
///
/// Requests block the calling thread until the reply lands, so nothing here
/// may be called from the main thread. Reports arrive on a private queue.
final class HIDPPLink {
    enum Transport {
        case receiver, bluetooth

        var description: String {
            switch self {
            case .receiver: return "USB receiver"
            case .bluetooth: return "Bluetooth"
            }
        }

        /// A receiver puts HID++ on a vendor-only interface, which any app may
        /// open. A mouse paired straight to Bluetooth carries HID++ on the
        /// mouse node itself, and opening a pointing device is guarded by
        /// Input Monitoring — a different permission from the Accessibility one
        /// the event tap needs.
        var needsInputMonitoring: Bool { self == .bluetooth }
    }

    let transport: Transport
    let productName: String
    /// Which device on the link answers: `1...6` behind a receiver, `0xFF` when
    /// the mouse is paired directly.
    private(set) var deviceIndex: UInt8 = 0xFF

    private let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let lock = NSLock()
    private var pending: Pending?
    private var isActive = false
    /// The device is serviced by a run loop of its own. It cannot be the main
    /// one: `request` blocks until the reply arrives, and a reply that needed
    /// the blocked run loop to be delivered would never come.
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let threadReady = DispatchSemaphore(value: 0)
    private let threadFinished = DispatchSemaphore(value: 0)

    /// Reports nobody asked for — a diverted button, a device waking up. Called
    /// on the private queue.
    var onNotification: (([UInt8]) -> Void)?

    private final class Pending {
        let device: UInt8, feature: UInt8, function: UInt8
        let semaphore = DispatchSemaphore(value: 0)
        var payload: [UInt8]?

        init(device: UInt8, feature: UInt8, function: UInt8) {
            self.device = device
            self.feature = feature
            self.function = function
        }
    }

    // MARK: - Finding a link

    /// Every Logitech node that carries HID++, receivers first: a receiver
    /// answers even when the mouse is asleep, which makes it the steadier of
    /// the two.
    static func candidates() -> [(device: IOHIDDevice, transport: Transport)] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        var found: [(IOHIDDevice, Transport)] = []
        for node in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
            let pairs = (IOHIDDeviceGetProperty(node, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]]) ?? []
            let pages = Set(pairs.compactMap { $0["DeviceUsagePage"] })
            if pages.contains(0xFF00) { found.append((node, .receiver)) }
            else if pages.contains(0xFF43) { found.append((node, .bluetooth)) }
        }
        return found.sorted { a, b in a.1 == .receiver && b.1 != .receiver }
            .map { (device: $0.0, transport: $0.1) }
    }

    init?(device: IOHIDDevice, transport: Transport) {
        self.device = device
        self.transport = transport
        self.productName = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "Logitech device"

        // Opening is what grants the right to send reports. It cannot be
        // combined with the dispatch-queue API, which traps on an open device,
        // so the run loop below is what carries the replies.
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            log.notice("HID++: could not open \(self.productName, privacy: .public) — 0x\(String(UInt32(bitPattern: opened), radix: 16), privacy: .public)")
            return nil
        }
        isActive = true

        let thread = Thread { [weak self] in self?.serviceReports() }
        thread.name = "com.digigara.Clix.hidpp"
        thread.stackSize = 128 * 1024
        self.thread = thread
        thread.start()
        threadReady.wait()
    }

    deinit {
        close()
        buffer.deallocate()
    }

    /// Runs on the private thread: services the device until `close` says stop.
    private func serviceReports() {
        runLoop = CFRunLoopGetCurrent()
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, reportID, report, length in
            guard let context, length > 0 else { return }
            let link = Unmanaged<HIDPPLink>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Some paths hand back the report id as the first byte and some do
            // not; normalise so the payload always starts at the device index.
            if bytes.first == UInt8(truncatingIfNeeded: reportID) { bytes.removeFirst() }
            link.receive(bytes)
        }, Unmanaged.passUnretained(self).toOpaque())
        threadReady.signal()

        while isActive {
            CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }

        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        threadFinished.signal()
    }

    /// Stops the link and waits for its thread, so nothing can still be using
    /// the report buffer once this returns.
    func close() {
        guard isActive else { return }
        isActive = false
        // Wake the loop so it notices straight away instead of at the next tick.
        if let runLoop { CFRunLoopWakeUp(runLoop) }
        threadFinished.wait()
        thread = nil
        runLoop = nil
    }

    // MARK: - Talking

    private func receive(_ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        lock.lock()
        if let pending = pending, payload[0] == pending.device {
            let isReply = payload[1] == pending.feature
                && payload[2] == (pending.function << 4) | HIDPP.softwareID
            // A HID++ 2.0 error names the feature it came from; a 1.0 error
            // uses sub-id 0x8F. Either way the request is over.
            let isError = (payload[1] == 0xFF && payload[2] == pending.feature) || payload[1] == 0x8F
            if isReply || isError {
                pending.payload = isReply ? Array(payload.dropFirst(3)) : nil
                self.pending = nil
                lock.unlock()
                pending.semaphore.signal()
                return
            }
        }
        lock.unlock()
        onNotification?(payload)
    }

    /// Sends one request and waits for its reply. Returns the parameters of the
    /// reply, or nil if the device refused or said nothing in time.
    @discardableResult
    func request(device deviceIndex: UInt8,
                 feature: UInt8,
                 function: UInt8,
                 params: [UInt8] = [],
                 timeout: TimeInterval = 1.0) -> [UInt8]? {
        let waiter = Pending(device: deviceIndex, feature: feature, function: function)
        lock.lock()
        pending = waiter
        lock.unlock()

        var payload = [UInt8](repeating: 0, count: 19)
        payload[0] = deviceIndex
        payload[1] = feature
        payload[2] = (function << 4) | HIDPP.softwareID
        for (offset, byte) in params.enumerated() where offset < 16 { payload[3 + offset] = byte }

        // IOHIDDeviceSetReport wants the report id both as its own argument and
        // as the leading byte of the buffer. Omitting it is accepted silently
        // over Bluetooth and rejected outright over USB.
        let report = [UInt8(HIDPP.longReport)] + payload
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, HIDPP.longReport, report, report.count) == kIOReturnSuccess else {
            lock.lock(); pending = nil; lock.unlock()
            return nil
        }

        if waiter.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); if pending === waiter { pending = nil }; lock.unlock()
            return nil
        }
        return waiter.payload
    }

    /// Finds which device on this link is awake and speaking HID++ 2.0.
    ///
    /// A sleeping mouse can miss the first ping and answer the second, so each
    /// address is tried more than once before it is written off.
    func locateDevice(attempts: Int = 2) -> Bool {
        let indices: [UInt8] = transport == .receiver ? [1, 2, 3, 4, 5, 6] : [0xFF]
        for _ in 0..<attempts {
            for index in indices {
                guard let reply = request(device: index, feature: 0, function: 1,
                                          params: [0, 0, 0xAF], timeout: 0.5),
                      reply.count >= 3, reply[2] == 0xAF else { continue }
                deviceIndex = index
                log.notice("HID++: \(self.productName, privacy: .public) answers at index \(index) over \(self.transport.description, privacy: .public)")
                return true
            }
        }
        return false
    }

    /// Looks a feature up by id. Returns nil when the device does not have it.
    func index(of feature: HIDPP.Feature) -> UInt8? {
        guard let reply = request(device: deviceIndex, feature: 0, function: 0,
                                  params: [UInt8(feature.rawValue >> 8), UInt8(feature.rawValue & 0xFF)]),
              let index = reply.first, index != 0 else { return nil }
        return index
    }
}
