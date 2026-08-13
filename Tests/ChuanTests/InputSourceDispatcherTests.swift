import Carbon
import CoreGraphics
import Testing
@testable import chuan

private let firstNonCJKVSource = SwitchableInputSource(
    id: "com.apple.keylayout.US",
    isCJKV: false
)
private let secondNonCJKVSource = SwitchableInputSource(
    id: "com.apple.keylayout.ABC",
    isCJKV: false
)
private let otherCJKVSource = SwitchableInputSource(
    id: "com.apple.inputmethod.Korean",
    isCJKV: true
)
private let cjkvInputMethod = SwitchableInputSource(
    id: "com.apple.inputmethod.Japanese",
    isCJKV: true
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
    var shortcut: PreviousInputSourceShortcut? = previousSourceShortcut
    var hasPostEventAccess = true
    var postEventAccessChecks = 0
    var operations: [SwitchOperation] = []
    var postedShortcuts: [PreviousInputSourceShortcut] = []

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

@Test("A non-CJKV source performs one direct selection")
@MainActor
func nonCJKVSourcePerformsOneDirectSelection() {
    let system = FakeInputSourceSwitchingSystem()
    let switcher = InputSourceSwitcher(system: system)
    switcher.prepare([firstNonCJKVSource])

    let error = switcher.switchTo(sourceID: firstNonCJKVSource.id)

    #expect(error == nil)
    #expect(system.operations == [.select(firstNonCJKVSource.id)])
    #expect(system.postEventAccessChecks == 0)
}

@Test("A CJKV source uses the first non-CJKV source before the native shortcut")
@MainActor
func cjkvSourceUsesTheFirstNonCJKVSource() {
    let system = FakeInputSourceSwitchingSystem()
    let switcher = InputSourceSwitcher(system: system)
    switcher.prepare([
        otherCJKVSource,
        firstNonCJKVSource,
        secondNonCJKVSource,
        cjkvInputMethod
    ])
    #expect(system.postEventAccessChecks == 0)

    let error = switcher.switchTo(sourceID: cjkvInputMethod.id)

    #expect(error == nil)
    #expect(system.operations == [
        .select(cjkvInputMethod.id),
        .select(firstNonCJKVSource.id),
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
    deniedSwitcher.prepare([firstNonCJKVSource, cjkvInputMethod])
    #expect(deniedSystem.postEventAccessChecks == 0)

    _ = deniedSwitcher.switchTo(sourceID: cjkvInputMethod.id)
    #expect(deniedSystem.postEventAccessChecks == 1)
    _ = deniedSwitcher.switchTo(sourceID: cjkvInputMethod.id)

    #expect(deniedErrors == [.postEventPermissionDenied])
    #expect(deniedSystem.operations.isEmpty)

    let missingShortcutSystem = FakeInputSourceSwitchingSystem()
    missingShortcutSystem.shortcut = nil
    var missingShortcutErrors: [InputSourceSwitchError] = []
    let missingShortcutSwitcher = InputSourceSwitcher(
        system: missingShortcutSystem,
        reportSetupFailure: { missingShortcutErrors.append($0) }
    )
    missingShortcutSwitcher.prepare([firstNonCJKVSource, cjkvInputMethod])
    #expect(missingShortcutSystem.postEventAccessChecks == 0)

    _ = missingShortcutSwitcher.switchTo(sourceID: cjkvInputMethod.id)
    _ = missingShortcutSwitcher.switchTo(sourceID: cjkvInputMethod.id)

    #expect(missingShortcutErrors == [.previousSourceShortcutUnavailable])
    #expect(missingShortcutSystem.operations.isEmpty)
}
