import AppKit
import Foundation
import KeyboardShortcuts

/// Owns the global shortcut handlers for each input source.
///
/// The shortcuts library *appends* handlers each time `onKeyDown(for:)` or
/// `onKeyUp(for:)` is called for a name, so registering the same source twice
/// would make each phase fire twice. We therefore register one handler per phase
/// exactly once and remember which sources we've seen, so the list can be
/// refreshed safely after the user adds a new input source.
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
            let switchInputSource = {
                precondition(Thread.isMainThread, "Input-source switching must run on main")
                MainActor.assumeIsolated {
                    _ = InputSourceSwitcher.shared.switchTo(sourceID: sourceID)
                }
            }
            KeyboardShortcuts.onKeyDown(
                for: source.shortcutName,
                action: switchInputSource
            )
            KeyboardShortcuts.onKeyUp(
                for: source.shortcutName,
                action: switchInputSource
            )
        }
    }
}
