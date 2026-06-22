import AppKit
import Carbon
import KeyboardShortcuts

/// A selectable keyboard input source, with its display metadata and the
/// action to make it the active source.
final class InputSource: Equatable {
    let source: TISInputSource
    let id: String
    let name: String
    let icon: NSImage?

    init?(source: TISInputSource) {
        guard let id = source.identifier else { return nil }
        self.source = source
        self.id = id
        self.name = source.localizedName ?? id
        self.icon = InputSource.loadIcon(for: source)
    }

    /// A stable, per-source key for storing and registering its shortcut.
    var shortcutName: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("inputsource_" + id)
    }

    func select() {
        TISSelectInputSource(source)
    }

    static func == (lhs: InputSource, rhs: InputSource) -> Bool {
        lhs.id == rhs.id
    }

    /// All currently enabled, selectable keyboard input sources.
    static var all: [InputSource] {
        let keyboardCategory = kTISCategoryKeyboardInputSource as String
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else {
            return []
        }
        let sources = (list as NSArray) as? [TISInputSource] ?? []
        return sources
            .filter { $0.category == keyboardCategory && $0.isSelectable }
            .compactMap { InputSource(source: $0) }
    }

    private static func loadIcon(for source: TISInputSource) -> NSImage? {
        if let url = source.iconImageURL {
            for candidate in [url.retinaVariant, url.tiffVariant, url] {
                if let image = NSImage(contentsOf: candidate) {
                    return image
                }
            }
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }
}

private extension URL {
    /// `foo.tiff` -> `foo@2x.tiff`
    var retinaVariant: URL {
        let ext = pathExtension
        let stem = deletingPathExtension().lastPathComponent
        return deletingLastPathComponent()
            .appendingPathComponent("\(stem)@2x")
            .appendingPathExtension(ext)
    }

    /// `foo.icns` -> `foo.tiff`
    var tiffVariant: URL {
        deletingPathExtension().appendingPathExtension("tiff")
    }
}
