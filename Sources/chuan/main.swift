import AppKit

// A menu-bar-only utility: no Dock icon, no main menu bar presence.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
