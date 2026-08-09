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
    var postEventAccessChecks = 0
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
        postEventAccessChecks += 1
        return hasPostEventAccess
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
    #expect(system.postEventAccessChecks == 0)
}

@Test("A complex source performs target, bridge, native key-down, and native key-up")
@MainActor
func complexSourcePerformsTheKawaSequence() {
    let system = FakeInputSourceSwitchingSystem()
    let switcher = InputSourceSwitcher(system: system)
    switcher.prepare([complexInputMethod])
    #expect(system.postEventAccessChecks == 0)

    let error = switcher.switchTo(sourceID: complexInputMethod.id)

    #expect(error == nil)
    #expect(system.operations == [
        .select(complexInputMethod.id),
        .select(asciiBridge.id),
        .nativeKeyDown,
        .nativeKeyUp
    ])
    #expect(system.postedShortcuts == [previousSourceShortcut])
    #expect(system.postEventAccessChecks == 1)
}

@Test("Missing permission or system shortcut reports once without selecting a source")
@MainActor
func missingSetupReportsOnceWithoutSelectingASource() {
    let deniedSystem = FakeInputSourceSwitchingSystem()
    deniedSystem.hasPostEventAccess = false
    var deniedErrors: [InputSourceSwitchError] = []
    let deniedSwitcher = InputSourceSwitcher(
        system: deniedSystem,
        reportSetupFailure: { deniedErrors.append($0) }
    )
    deniedSwitcher.prepare([complexInputMethod])
    #expect(deniedSystem.postEventAccessChecks == 0)

    _ = deniedSwitcher.switchTo(sourceID: complexInputMethod.id)
    #expect(deniedSystem.postEventAccessChecks == 1)
    _ = deniedSwitcher.switchTo(sourceID: complexInputMethod.id)

    #expect(deniedErrors == [.postEventPermissionDenied])
    #expect(deniedSystem.operations.isEmpty)

    let missingShortcutSystem = FakeInputSourceSwitchingSystem()
    missingShortcutSystem.shortcut = nil
    var missingShortcutErrors: [InputSourceSwitchError] = []
    let missingShortcutSwitcher = InputSourceSwitcher(
        system: missingShortcutSystem,
        reportSetupFailure: { missingShortcutErrors.append($0) }
    )
    missingShortcutSwitcher.prepare([complexInputMethod])
    #expect(missingShortcutSystem.postEventAccessChecks == 0)

    _ = missingShortcutSwitcher.switchTo(sourceID: complexInputMethod.id)
    _ = missingShortcutSwitcher.switchTo(sourceID: complexInputMethod.id)

    #expect(missingShortcutErrors == [.previousSourceShortcutUnavailable])
    #expect(missingShortcutSystem.operations.isEmpty)
}
