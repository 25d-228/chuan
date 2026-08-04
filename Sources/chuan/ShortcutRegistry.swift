import AppKit
import KeyboardShortcuts

/// Owns the global shortcut handlers, one per input source.
///
/// The shortcuts library *appends* a handler each time `onKeyUp(for:)` is
/// called for a name, so registering the same source twice would make it fire
/// twice. We therefore register each source's handler exactly once and remember
/// which we've seen, so the list can be refreshed safely after the user adds a
/// new input source.
final class ShortcutRegistry {
    static let shared = ShortcutRegistry()

    private var registered = Set<String>()

    private init() {}

    /// Register handlers for any current sources not yet registered. Idempotent.
    func sync() {
        for source in InputSource.all where !registered.contains(source.id) {
            registered.insert(source.id)
            KeyboardShortcuts.onKeyUp(for: source.shortcutName) {
                Task { @MainActor in
                    do {
                        try await InputSourceSelector.shared.select(source)
                    } catch {
                        NSLog("Input-source shortcut failed: %@", error.localizedDescription)
                    }
                }
            }
        }
    }
}
