import Carbon
import Foundation

/// Thin, typed accessors over the Text Input Source (TIS) property API.
extension TISInputSource {
    private func propertyValue(_ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    var identifier: String? {
        propertyValue(kTISPropertyInputSourceID) as? String
    }

    var localizedName: String? {
        propertyValue(kTISPropertyLocalizedName) as? String
    }

    var category: String? {
        propertyValue(kTISPropertyInputSourceCategory) as? String
    }

    var inputSourceType: String? {
        propertyValue(kTISPropertyInputSourceType) as? String
    }

    var isSelectable: Bool {
        (propertyValue(kTISPropertyInputSourceIsSelectCapable) as? Bool) ?? false
    }

    var isEnabled: Bool {
        (propertyValue(kTISPropertyInputSourceIsEnabled) as? Bool) ?? false
    }

    var isASCIICapable: Bool {
        (propertyValue(kTISPropertyInputSourceIsASCIICapable) as? Bool) ?? false
    }

    var iconImageURL: URL? {
        propertyValue(kTISPropertyIconImageURL) as? URL
    }
}
