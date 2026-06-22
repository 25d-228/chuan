import Foundation

/// Small typed wrapper over `UserDefaults` for the app's own preferences.
/// (Per-source shortcuts are stored separately by the shortcuts library.)
enum Storage {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    static var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }
}
