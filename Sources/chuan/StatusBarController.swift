import AppKit

/// Owns the menu-bar status item and its menu.
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let openPreferences: () -> Void

    init(openPreferences: @escaping () -> Void) {
        self.openPreferences = openPreferences
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "globe", accessibilityDescription: "chuan")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "chuan"
        }

        let menu = NSMenu()
        let prefsItem = NSMenuItem(title: "Preferences…",
                                   action: #selector(handlePreferences),
                                   keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit chuan",
                                  action: #selector(handleQuit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func handlePreferences() {
        openPreferences()
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}
