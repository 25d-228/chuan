// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "chuan",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Pinned to 1.15.0: later releases use the SwiftUI `#Preview` macro,
        // whose compiler plugin ships only with full Xcode (not the Command
        // Line Tools), so they fail to build here. 1.15.0 has the same API.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0")
    ],
    targets: [
        .executableTarget(
            name: "chuan",
            dependencies: [
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ]
        )
    ]
)
