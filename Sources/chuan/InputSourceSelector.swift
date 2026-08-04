import AppKit
import Carbon
import Foundation

struct InputSourceSelectionError: LocalizedError {
    let sourceID: String
    let status: OSStatus

    var errorDescription: String? {
        "Could not select input source \(sourceID) (TIS status \(status))"
    }
}

@MainActor
final class InputSourceSelector {
    static let shared = InputSourceSelector()

    private static let shortcutModifiers: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift
    ]

    private init() {}

    func select(_ inputSource: InputSource) async throws {
        let previousInputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let isKeyboardLayout = inputSource.source.inputSourceType == kTISTypeKeyboardLayout as String

        if !isKeyboardLayout {
            // Poll every 10 ms to avoid the Input Monitoring permission required by a global monitor.
            while !NSEvent.modifierFlags.intersection(Self.shortcutModifiers).isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        try performSelection(inputSource.source)

        guard !isKeyboardLayout, let previousInputSource,
              previousInputSource.identifier != inputSource.id else {
            return
        }

        // Some text clients only rebind an input method after observing a complete source transition.
        try performSelection(previousInputSource)
        try performSelection(inputSource.source)
    }

    private func performSelection(_ inputSource: TISInputSource) throws {
        let status = TISSelectInputSource(inputSource)
        guard status == noErr else {
            throw InputSourceSelectionError(
                sourceID: inputSource.identifier ?? "unknown",
                status: status
            )
        }
    }
}
