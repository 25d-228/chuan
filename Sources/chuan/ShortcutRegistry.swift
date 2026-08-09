import AppKit
import Foundation
import KeyboardShortcuts

/// Owns the global shortcut handlers, one per input source.
///
/// The shortcuts library *appends* a handler each time `onKeyUp(for:)` is
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
        let dispatchSources = sources.map(DispatchInputSource.init)
        let shortcutSignatures = Dictionary(uniqueKeysWithValues: sources.compactMap { source in
            KeyboardShortcuts.getShortcut(for: source.shortcutName).map {
                (
                    source.id,
                    ShortcutSignature(
                        keyCode: $0.carbonKeyCode,
                        carbonModifiers: $0.carbonModifiers
                    )
                )
            }
        })
        InputSourceSelector.shared.prepare(
            dispatchSources,
            shortcutSignatures: shortcutSignatures
        )

        for source in sources where !registered.contains(source.id) {
            registered.insert(source.id)
            let sourceID = source.id
            KeyboardShortcuts.onKeyUp(for: source.shortcutName) {
                let callbackEnteredAt = DispatchTime.now().uptimeNanoseconds
                Self.synchronouslyOnMainThread {
                    let selector = InputSourceSelector.shared
                    guard selector.shouldHandleShortcut(for: sourceID) else {
                        return
                    }
                    let result = selector.dispatch(
                        sourceID: sourceID,
                        callbackEnteredAt: callbackEnteredAt
                    )
                    if let verification = result.verification {
                        DispatchQueue.main.async {
                            InputSourceSelector.shared.scheduleVerification(verification)
                        }
                    }
                }
            }
        }
    }

    nonisolated static func synchronouslyOnMainThread(
        _ action: @escaping @MainActor () -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                action()
            }
            return
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                action()
            }
        }
    }
}
