import AppKit

/// A single, reusable preferences window.
///
/// While the window is open the app becomes a regular app (Dock icon, visible
/// menu bar, manageable by tiling window managers); when it closes the app
/// returns to being a menu-bar-only accessory.
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "chuan"
        window.isReleasedWhenClosed = false
        window.backgroundColor = Palette.paper
        window.contentMinSize = NSSize(width: 460, height: 420)
        window.contentViewController = PreferencesViewController()
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
