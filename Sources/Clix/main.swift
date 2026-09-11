import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu bar only: no Dock icon, no main menu.
application.setActivationPolicy(.accessory)
application.run()
