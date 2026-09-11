import AppKit
import ApplicationServices
import Combine
import Foundation

/// Tracks whether Clix is trusted for Accessibility, which the event tap needs.
///
/// macOS gives no notification when the switch is flipped, so this polls for
/// it — in both directions, since access can be revoked while Clix is running.
final class AccessibilityMonitor: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var timer: Timer?

    /// Called on the main queue whenever access is granted or revoked.
    var onChange: ((Bool) -> Void)?

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        onChange?(trusted)
    }

    /// Shows the system prompt that offers to open Privacy & Security settings.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        startPolling()
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
