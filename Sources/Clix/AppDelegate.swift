import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = BindingStore()
    private let accessibility = AccessibilityMonitor()
    private let tap = MouseEventTap()
    private let trackpad = TrackpadMonitor()
    private let sideButtons = LogitechSideButtons()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    /// The safety net that brings the icon back when it has been hidden.
    private let globalHotkey = GlobalHotkey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        // React to menu bar visibility changes outside the Settings window's
        // view life cycle: this drives the icon the moment the toggle flips,
        // without relying on SwiftUI's `.onChange`.
        store.onHideMenuBarIconChange = { [weak self] in
            self?.applyMenuBarVisibility()
        }
        applyMenuBarVisibility()
        wireTap()

        accessibility.onChange = { [weak self] _ in
            self?.syncTapState()
            self?.updateStatusItemAppearance()
        }
        accessibility.startPolling()
        sideButtons.scan()
        syncSideButtons()

        if accessibility.isTrusted {
            syncTapState()
        } else {
            accessibility.requestAccess()
        }

        // Opening Clix means asking for its window: bring up Settings. When
        // Accessibility is missing the Settings window shows the permission
        // gate instead of the editor.
        showSettings(nil)

        updateStatusItemAppearance()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        trackpad.stop()
        // Hand the side buttons back before going away, or they stay diverted
        // to an app that is no longer listening.
        sideButtons.shutDown()
    }

    // MARK: - Tap

    private func wireTap() {
        tap.shouldHandle = { [store] button in
            guard store.isEnabled else { return false }
            return store.isDetecting || store.action(for: button) != nil
        }
        tap.onButton = { [store] button, phase in
            guard store.isEnabled, !store.isDetecting,
                  let binding = store.binding(for: .button(button)),
                  binding.trigger == phase else { return }
            store.lastActivity = "\(MouseButton.name(for: button)) → \(binding.action.summary)"
            ActionRunner.perform(binding.action)
        }
        trackpad.onGesture = { [store] gesture in
            store.noteSeen(gesture: gesture)
            guard store.isEnabled, !store.isDetecting else { return }
            guard let action = store.action(for: .gesture(gesture)) else {
                store.lastActivity = "\(gesture.title) → not bound"
                return
            }
            store.lastActivity = "\(gesture.title) → \(action.summary)"
            ActionRunner.perform(action)
        }
        // A diverted button never reaches the tap, so it is routed into the
        // same handlers by hand.
        sideButtons.isBound = { [store] button in
            store.isEnabled && !store.isDetecting && store.action(for: button) != nil
        }
        sideButtons.onButton = { [store] button, phase in
            guard store.isEnabled, !store.isDetecting,
                  let binding = store.binding(for: .button(button)),
                  binding.trigger == phase else { return }
            store.lastActivity = "\(MouseButton.name(for: button)) → \(binding.action.summary)"
            ActionRunner.perform(binding.action)
        }
        sideButtons.onButtonSeen = { [store] button in
            store.noteSeen(button: button)
            if store.action(for: button) == nil {
                store.lastActivity = "\(MouseButton.name(for: button)) → not bound"
            }
        }

        tap.onButtonSeen = { [store] button in
            store.noteSeen(button: button)
            if store.action(for: button) == nil {
                store.lastActivity = "\(MouseButton.name(for: button)) → not bound"
            }
        }
    }

    /// The takeover follows both switches: turning Clix off has to give the
    /// buttons back, not just stop acting on them.
    private func syncSideButtons() {
        sideButtons.setEnabled(store.isEnabled && store.instantSideButtons)
    }

    private func syncTapState() {
        // The trackpad monitor reads contacts directly and does not need
        // Accessibility, so it follows the on/off switch alone.
        if store.isEnabled { trackpad.start() } else { trackpad.stop() }

        guard accessibility.isTrusted, store.isEnabled else {
            tap.stop()
            return
        }
        do {
            try tap.start()
        } catch {
            log.error("\(error.localizedDescription, privacy: .public)")
            accessibility.startPolling()
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "computermouse.fill",
                                     accessibilityDescription: "Clix")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Enable Clix",
                                action: #selector(toggleEnabled(_:)),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(showSettings(_:)),
                                  keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Clix",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func updateStatusItemAppearance() {
        statusItem?.button?.appearsDisabled = !(store.isEnabled && accessibility.isTrusted)
    }

    /// Shows or hides the menu bar icon to match the persisted setting.
    ///
    /// While the icon is hidden the app is unreachable — no Dock icon, no main
    /// menu — so the safety-net hotkey is armed at the same time. It un-hides
    /// the icon and opens Settings; there is no other way back in.
    private func applyMenuBarVisibility() {
        if store.hideMenuBarIcon {
            if let statusItem {
                // nil-ing the property alone does not reliably remove the item
                // from the menu bar on modern macOS; removeStatusItem is the
                // path that actually clears the icon.
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            globalHotkey.register { [weak self] in
                // Setting the flag un-hides the icon via the model hook.
                self?.store.hideMenuBarIcon = false
                self?.showSettings(nil)
            }
        } else {
            globalHotkey.unregister()
            if statusItem == nil { setUpStatusItem() }
            updateStatusItemAppearance()
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        store.isEnabled.toggle()
        syncTapState()
        syncSideButtons()
        updateStatusItemAppearance()
    }

    // MARK: - Settings window

    @objc func showSettings(_ sender: Any?) {
        accessibility.refresh()

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsView(store: store, accessibility: accessibility, tap: tap,
                                trackpad: trackpad, sideButtons: sideButtons)
            .onChange(of: store.isEnabled) { [weak self] _ in
                self?.syncTapState()
                self?.syncSideButtons()
                self?.updateStatusItemAppearance()
            }
            .onChange(of: store.instantSideButtons) { [weak self] _ in
                self?.syncSideButtons()
            }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clix"
        window.contentViewController = NSHostingController(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        accessibility.refresh()
        menu.item(at: 0)?.state = store.isEnabled ? .on : .off
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
    }
}
