import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController { [weak self] in
            self?.showPreferences()
        }

        // Bind a global handler to every current input source.
        ShortcutRegistry.shared.sync()

        if !Storage.hasLaunchedBefore {
            Storage.hasLaunchedBefore = true
            showPreferences()
        }
    }

    private func showPreferences() {
        PreferencesWindowController.shared.showAndActivate()
    }
}
