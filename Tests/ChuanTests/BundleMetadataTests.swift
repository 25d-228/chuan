import Foundation
import Testing

@Test("Info.plist preserves the menu-bar-only bundle identity and minimum system version")
func infoPlistKeepsMenuBarOnlyBundleIdentityAndMinimumSystemVersion() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Info.plist"))
    let metadata = try #require(
        try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )

    #expect(metadata["LSUIElement"] as? Bool == true)
    #expect(metadata["LSMinimumSystemVersion"] as? String == "13.0")
    #expect(metadata["CFBundleExecutable"] as? String == "chuan")
    #expect(metadata["CFBundleIdentifier"] as? String == "com.chuan.Chuan")
    #expect(metadata["CFBundleName"] as? String == "Chuan")
}
