import Carbon
import CoreGraphics
import Testing
@testable import chuan

private let ordinaryLayout = SwitchableInputSource(
    id: "com.apple.keylayout.US",
    isKeyboardLayout: true
)
private let asciiBridge = SwitchableInputSource(
    id: "com.apple.keylayout.ABC",
    isKeyboardLayout: true
)
private let complexInputMethod = SwitchableInputSource(
    id: "com.apple.inputmethod.Japanese",
    isKeyboardLayout: false
)
private let previousSourceShortcut = PreviousInputSourceShortcut(
    keyCode: 49,
    flags: .maskControl
)

private enum SwitchOperation: Equatable {
    case select(String)
    case nativeKeyDown
    case nativeKeyUp
}

@MainActor
private final class FakeInputSourceSwitchingSystem: InputSourceSwitchingSystem {
    var bridgeSources = [asciiBridge]
    var shortcut: PreviousInputSourceShortcut? = previousSourceShortcut
    var hasPostEventAccess = true
    var operations: [SwitchOperation] = []
    var postedShortcuts: [PreviousInputSourceShortcut] = []

    func asciiCapableKeyboardLayouts() -> [SwitchableInputSource] {
        bridgeSources
    }

    func previousInputSourceShortcut() throws -> PreviousInputSourceShortcut {
        guard let shortcut else {
            throw InputSourceSwitchError.previousSourceShortcutUnavailable
        }
        return shortcut
    }

    func ensurePostEventAccess() -> Bool {
        hasPostEventAccess
    }

    func select(_ inputSource: SwitchableInputSource) -> OSStatus {
        operations.append(.select(inputSource.id))
        return noErr
    }

    func postPreviousInputSourceShortcut(_ shortcut: PreviousInputSourceShortcut) -> Bool {
        postedShortcuts.append(shortcut)
        operations.append(.nativeKeyDown)
        operations.append(.nativeKeyUp)
        return true
    }
}

@Test("An ordinary layout performs one direct selection")
@MainActor
func ordinaryLayoutPerformsOneDirectSelection() {
    let system = FakeInputSourceSwitchingSystem()
    let switcher = InputSourceSwitcher(system: system)
    switcher.prepare([ordinaryLayout])

    let error = switcher.switchTo(sourceID: ordinaryLayout.id)

    #expect(error == nil)
    #expect(system.operations == [.select(ordinaryLayout.id)])
}

@Test("A complex source performs target, bridge, native key-down, and native key-up")
@MainActor
func complexSourcePerformsTheKawaSequence() {
    let system = FakeInputSourceSwitchingSystem()
    let switcher = InputSourceSwitcher(system: system)
    switcher.prepare([complexInputMethod])

    let error = switcher.switchTo(sourceID: complexInputMethod.id)

    #expect(error == nil)
    #expect(system.operations == [
        .select(complexInputMethod.id),
        .select(asciiBridge.id),
        .nativeKeyDown,
        .nativeKeyUp
    ])
    #expect(system.postedShortcuts == [previousSourceShortcut])
}

@Test("Missing permission or system shortcut reports once without selecting a source")
@MainActor
func missingSetupReportsOnceWithoutSelectingASource() {
    for missingPermission in [false, true] {
        let system = FakeInputSourceSwitchingSystem()
        let expectedError: InputSourceSwitchError
        if missingPermission {
            system.hasPostEventAccess = false
            expectedError = .postEventPermissionDenied
        } else {
            system.shortcut = nil
            expectedError = .previousSourceShortcutUnavailable
        }
        var reportedErrors: [InputSourceSwitchError] = []
        let switcher = InputSourceSwitcher(
            system: system,
            reportSetupFailure: { reportedErrors.append($0) }
        )
        switcher.prepare([complexInputMethod])

        _ = switcher.switchTo(sourceID: complexInputMethod.id)
        _ = switcher.switchTo(sourceID: complexInputMethod.id)

        #expect(reportedErrors == [expectedError])
        #expect(system.operations.isEmpty)
    }
}
