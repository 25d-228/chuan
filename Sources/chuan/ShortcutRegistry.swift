import AppKit
import Foundation
import KeyboardShortcuts

/// Owns the global shortcut handlers, one per input source.
///
/// The shortcuts library *appends* a handler each time `onKeyDown(for:)` is
/// called for a name, so registering the same source twice would make it fire
/// twice. We therefore register each source's handler exactly once and remember
/// which we've seen, so the list can be refreshed safely after the user adds a
/// new input source.
@MainActor
final class ShortcutRegistry {
    static let shared = ShortcutRegistry()

    private var registered = Set<String>()

    private init() {}

    /// Register handlers for any current sources not yet registered. Idempotent.
    func sync() {
        let sources = InputSource.all
        InputSourceSwitcher.shared.prepare(sources.map(SwitchableInputSource.init))

        for source in sources where !registered.contains(source.id) {
            registered.insert(source.id)
            let sourceID = source.id
            KeyboardShortcuts.onKeyDown(for: source.shortcutName) {
                precondition(Thread.isMainThread, "Input-source switching must run on main")
                // Match Kawa by releasing the action from the Carbon callback.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = InputSourceSwitcher.shared.switchTo(sourceID: sourceID)
                    }
                }
            }
        }
    }
}
