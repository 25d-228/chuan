import AppKit
import Carbon
import CoreGraphics
import Foundation
import KeyboardShortcuts
import Testing
@testable import chuan

@Test("ordinary keyboard layout performs one direct checked selection")
@MainActor
func ordinaryKeyboardLayoutPerformsOneDirectCheckedSelection() async throws {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-b"] = sourceState(id: "layout-b")
    let handoff = makeHandoff(system: system, center: center)

    try await handoff.select(
        InputSourceSelectionTarget(id: "layout-b", isKeyboardLayout: true),
        isSuperseded: { false }
    )

    #expect(system.operations == ["select:layout-b"])
    #expect(system.shortcutReadCount == 0)
    #expect(system.permissionCheckCount == 0)
}

@Test("input method observes target, bridge, and native previous phases in order")
@MainActor
func inputMethodObservesNativeHandoffPhasesInOrder() async throws {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    let handoff = makeHandoff(system: system, center: center)

    try await handoff.select(
        InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
        isSuperseded: { false }
    )

    #expect(system.operations == [
        "select:method-b",
        "select:layout-a",
        "native-previous"
    ])
    #expect(system.currentSourceID == "method-b")
}

@Test("input method already current still performs the repair transaction")
@MainActor
func currentInputMethodStillPerformsRepairTransaction() async throws {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "method-b",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    let handoff = makeHandoff(system: system, center: center)

    try await handoff.select(
        InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
        isSuperseded: { false }
    )

    #expect(system.operations == [
        "select:method-b",
        "select:layout-a",
        "native-previous"
    ])
    #expect(system.currentSourceID == "method-b")
}

@Test("bridge resolution prefers the current safe keyboard layout")
func bridgeResolutionPrefersCurrentSafeKeyboardLayout() {
    let preferred = sourceState(id: "layout-z")
    let candidates = [
        sourceState(id: "layout-a"),
        sourceState(id: "complex", isKeyboardLayout: false)
    ]

    let bridge = NativeInputSourceHandoff.resolveBridge(
        preferred: preferred,
        candidates: candidates,
        targetID: "method-b"
    )

    #expect(bridge == preferred)
}

@Test("bridge resolution falls back to an enabled ASCII keyboard layout")
func bridgeResolutionUsesEnabledASCIIKeyboardLayout() {
    let candidates = [
        sourceState(id: "complex", isKeyboardLayout: false),
        sourceState(id: "layout-disabled", isEnabled: false),
        sourceState(id: "layout-non-ascii", isASCIICapable: false),
        sourceState(id: "layout-b"),
        sourceState(id: "layout-a")
    ]

    let bridge = NativeInputSourceHandoff.resolveBridge(
        preferred: sourceState(id: "complex-current", isKeyboardLayout: false),
        candidates: candidates,
        targetID: "method-b"
    )

    #expect(bridge?.id == "layout-a")
}

@Test("unavailable ASCII-capable source discovery returns an empty list")
func unavailableASCIICapableSourceDiscoveryReturnsEmptyList() {
    #expect(
        LiveInputSourceHandoffSystem.inputSourceStates(from: nil).isEmpty
    )
}

@Test("empty ASCII-capable source discovery returns an empty list")
func emptyASCIICapableSourceDiscoveryReturnsEmptyList() {
    let emptyList = Unmanaged.passRetained(NSArray() as CFArray)

    #expect(
        LiveInputSourceHandoffSystem.inputSourceStates(from: emptyList).isEmpty
    )
}

@Test("symbolic hotkey 60 parses key code and explicitly converts modifiers")
func symbolicHotKeyParsesKeyCodeAndModifiers() throws {
    let storedModifiers = CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskShift.rawValue
    let shortcut = try SymbolicHotKeyParser.previousInputSourceShortcut(
        from: symbolicHotKeyDomain(
            enabled: true,
            parameters: [32, 49, storedModifiers]
        )
    )

    #expect(shortcut.keyCode == 49)
    #expect(shortcut.eventFlags == [.maskControl, .maskShift])
    #expect(shortcut.carbonModifiers == controlKey | shiftKey)
}

@Test("disabled symbolic hotkey 60 fails explicitly")
func disabledSymbolicHotKeyFailsExplicitly() {
    #expect(throws: SymbolicHotKeyError.disabled) {
        try SymbolicHotKeyParser.previousInputSourceShortcut(
            from: symbolicHotKeyDomain(enabled: false, parameters: [32, 49, 0])
        )
    }
}

@Test("malformed symbolic hotkey 60 fails explicitly")
func malformedSymbolicHotKeyFailsExplicitly() {
    #expect(throws: SymbolicHotKeyError.malformed) {
        try SymbolicHotKeyParser.previousInputSourceShortcut(
            from: symbolicHotKeyDomain(enabled: true, parameters: [32])
        )
    }
}

@Test("absent symbolic hotkey 60 fails explicitly")
func absentSymbolicHotKeyFailsExplicitly() {
    #expect(throws: SymbolicHotKeyError.missing) {
        try SymbolicHotKeyParser.previousInputSourceShortcut(from: [:])
    }
}

@Test("PostEvent preflight success does not request permission")
func postEventPreflightSuccessDoesNotRequestPermission() {
    var access = PostEventAccessController()
    var requestCount = 0

    let state = access.ensureAccess(
        preflight: { true },
        request: {
            requestCount += 1
            return true
        }
    )

    #expect(state == .preflightGranted)
    #expect(requestCount == 0)
}

@Test("PostEvent request success grants first native handoff")
func postEventRequestSuccessGrantsFirstNativeHandoff() {
    var access = PostEventAccessController()
    var requestCount = 0

    let state = access.ensureAccess(
        preflight: { false },
        request: {
            requestCount += 1
            return true
        }
    )

    #expect(state == .requestGranted)
    #expect(requestCount == 1)
}

@Test("PostEvent denial is reported without repeatedly requesting permission")
func postEventDenialDoesNotRepeatPermissionRequest() {
    var access = PostEventAccessController()
    var requestCount = 0
    let request = {
        requestCount += 1
        return false
    }

    let firstState = access.ensureAccess(preflight: { false }, request: request)
    let secondState = access.ensureAccess(preflight: { false }, request: request)

    #expect(firstState == .denied)
    #expect(secondState == .denied)
    #expect(requestCount == 1)
}

@Test("notification and current-source mismatch waits for the expected ID")
@MainActor
func notificationCurrentSourceMismatchWaitsForExpectedID() async throws {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    system.delayedTransitionReads["method-b"] = 3
    let handoff = makeHandoff(system: system, center: center)

    try await handoff.select(
        InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
        isSuperseded: { false }
    )

    #expect(system.completedDelayedTransitions.contains("method-b"))
    #expect(system.currentSourceID == "method-b")
}

@Test("native transition timeout fails and restores the target from the bridge")
@MainActor
func nativeTransitionTimeoutRestoresTargetFromBridge() async {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    system.nativeTransitionIsStalled = true
    let handoff = makeHandoff(system: system, center: center, phaseTimeout: 0.03)

    await #expect(throws: InputSourceHandoffError.self) {
        try await handoff.select(
            InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
            isSuperseded: { false }
        )
    }

    #expect(system.operations == [
        "select:method-b",
        "select:layout-a",
        "native-previous",
        "select:method-b"
    ])
    #expect(system.currentSourceID == "method-b")
}

@Test("non-noErr target selection fails before bridge or native phases")
@MainActor
func targetSelectionFailureStopsHandoff() async {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    system.selectionStatuses["method-b"] = OSStatus(paramErr)
    let handoff = makeHandoff(system: system, center: center)

    await #expect(throws: InputSourceHandoffError.self) {
        try await handoff.select(
            InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
            isSuperseded: { false }
        )
    }

    #expect(system.operations == ["select:method-b"])
    #expect(system.currentSourceID == "layout-a")
}

@Test("permission denial fails before changing the current input source")
@MainActor
func permissionDenialDoesNotChangeCurrentSource() async {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    system.permissionState = .denied
    let handoff = makeHandoff(system: system, center: center)

    await #expect(throws: InputSourceHandoffError.self) {
        try await handoff.select(
            InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
            isSuperseded: { false }
        )
    }

    #expect(system.operations.isEmpty)
    #expect(system.currentSourceID == "layout-a")
}

@Test("empty bridge discovery follows the no-bridge failure path")
@MainActor
func emptyBridgeDiscoveryReportsNoBridge() async {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "method-current",
        notificationCenter: center
    )
    system.states["method-current"] = sourceState(
        id: "method-current",
        isKeyboardLayout: false,
        isASCIICapable: false
    )
    system.states["method-b"] = sourceState(
        id: "method-b",
        isKeyboardLayout: false,
        isASCIICapable: false
    )
    let handoff = makeHandoff(system: system, center: center)

    await #expect(throws: InputSourceHandoffError.noBridge("method-b")) {
        try await handoff.select(
            InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
            isSuperseded: { false }
        )
    }

    #expect(system.operations.isEmpty)
    #expect(system.currentSourceID == "method-current")
}

@Test("superseded request stops after seeding the target and never leaves a bridge active")
@MainActor
func supersededRequestStopsBeforeBridge() async {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    let handoff = makeHandoff(system: system, center: center)
    var cancellationChecks = 0

    await #expect(throws: SupersededInputSourceRequest.self) {
        try await handoff.select(
            InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
            isSuperseded: {
                cancellationChecks += 1
                return cancellationChecks == 3
            }
        )
    }

    #expect(system.operations == ["select:method-b"])
    #expect(system.currentSourceID == "method-b")
}

@Test("rapid requests are serialized and only the latest pending target runs")
@MainActor
func rapidRequestsAreSerializedWithLatestPendingTargetWinning() async throws {
    let selection = SlowFakeSelection()
    let selector = InputSourceSelector(selection: selection, reportFailure: { _ in })
    let first = InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false)
    let intermediate = InputSourceSelectionTarget(id: "layout-a", isKeyboardLayout: true)
    let latest = InputSourceSelectionTarget(id: "layout-c", isKeyboardLayout: true)

    selector.request(first)
    try await waitUntil { !selection.startedTargets.isEmpty }
    selector.request(intermediate)
    selector.request(latest)
    try await waitUntil { selector.isIdle }

    #expect(selection.startedTargets == [first, latest])
    #expect(selection.completedTargets == [latest])
    #expect(selection.maximumConcurrentSelections == 1)
}

@Test("internally posted native shortcut is marked throughout delivery")
@MainActor
func internallyPostedShortcutIsMarkedDuringDelivery() async throws {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    let handoff = makeHandoff(system: system, center: center)
    var wasMarked = false
    system.onPost = { shortcut in
        wasMarked = handoff.isSuppressingInternallyPostedShortcut(
            shortcut.signature
        )
    }

    try await handoff.select(
        InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false),
        isSuperseded: { false }
    )

    #expect(wasMarked)
    #expect(
        handoff.isSuppressingInternallyPostedShortcut(
            system.shortcut.signature
        )
    )
    #expect(handoff.consumeInternallyPostedShortcut(system.shortcut.signature))
    #expect(
        !handoff.isSuppressingInternallyPostedShortcut(
            system.shortcut.signature
        )
    )
}

@Test("delayed internally posted callback cannot recursively enqueue a selection")
@MainActor
func delayedInternallyPostedCallbackCannotEnqueueSelection() async throws {
    let center = NotificationCenter()
    let system = FakeInputSourceHandoffSystem(
        currentSourceID: "layout-a",
        notificationCenter: center
    )
    system.states["layout-a"] = sourceState(id: "layout-a")
    system.states["method-b"] = sourceState(id: "method-b", isKeyboardLayout: false)
    let handoff = makeHandoff(system: system, center: center)
    let selector = InputSourceSelector(selection: handoff, reportFailure: { _ in })
    let target = InputSourceSelectionTarget(id: "method-b", isKeyboardLayout: false)
    var delayedCallback: (() -> Void)?
    var callbackWasDelivered = false
    system.onPost = { shortcut in
        delayedCallback = {
            Task { @MainActor in
                if selector.shouldHandleShortcut(shortcut.signature) {
                    selector.request(target)
                }
                callbackWasDelivered = true
            }
        }
    }

    selector.request(target)
    try await waitUntil { selector.isIdle }
    let completedOperations = system.operations
    let callback = try #require(delayedCallback)
    callback()
    try await waitUntil { callbackWasDelivered }

    #expect(system.operations == completedOperations)
    #expect(selector.isIdle)
}

private func sourceState(
    id: String,
    isKeyboardLayout: Bool = true,
    isASCIICapable: Bool = true,
    isEnabled: Bool = true,
    isSelectable: Bool = true
) -> InputSourceState {
    InputSourceState(
        id: id,
        isKeyboardLayout: isKeyboardLayout,
        isASCIICapable: isASCIICapable,
        isEnabled: isEnabled,
        isSelectable: isSelectable
    )
}

private func symbolicHotKeyDomain(
    enabled: Bool,
    parameters: [Any]
) -> [String: Any] {
    [
        "AppleSymbolicHotKeys": [
            "60": [
                "enabled": enabled,
                "value": [
                    "type": "standard",
                    "parameters": parameters
                ]
            ]
        ]
    ]
}

@MainActor
private func makeHandoff(
    system: FakeInputSourceHandoffSystem,
    center: NotificationCenter,
    phaseTimeout: TimeInterval = 0.1
) -> NativeInputSourceHandoff {
    NativeInputSourceHandoff(
        system: system,
        notificationCenter: center,
        phaseTimeout: phaseTimeout,
        diagnostics: { _ in }
    )
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(1)
    while !condition() {
        guard Date() < deadline else {
            throw InputSourceHandoffError.transitionTimedOut(
                phase: "test-wait",
                expectedID: "condition",
                currentID: nil
            )
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
private final class FakeInputSourceHandoffSystem: InputSourceHandoffSystem {
    struct DelayedTransition {
        let sourceID: String
        var remainingReads: Int
    }

    let notificationCenter: NotificationCenter
    var shortcutModifierFlags: NSEvent.ModifierFlags = []
    var states: [String: InputSourceState] = [:]
    var selectionStatuses: [String: OSStatus] = [:]
    var delayedTransitionReads: [String: Int] = [:]
    var completedDelayedTransitions = Set<String>()
    var permissionState: PostEventPermissionState = .preflightGranted
    var nativeTransitionIsStalled = false
    var operations: [String] = []
    var shortcutReadCount = 0
    var permissionCheckCount = 0
    var onPost: ((NativePreviousInputSourceShortcut) -> Void)?
    let shortcut = NativePreviousInputSourceShortcut(
        keyCode: 49,
        eventFlagsRawValue: CGEventFlags.maskControl.rawValue,
        carbonModifiers: controlKey
    )

    private var selectedSourceID: String?
    private var previousSourceID: String?
    private var delayedTransition: DelayedTransition?

    init(
        currentSourceID: String,
        notificationCenter: NotificationCenter
    ) {
        selectedSourceID = currentSourceID
        self.notificationCenter = notificationCenter
    }

    var currentSourceID: String? {
        if var delayedTransition {
            if delayedTransition.remainingReads == 0 {
                previousSourceID = selectedSourceID
                selectedSourceID = delayedTransition.sourceID
                completedDelayedTransitions.insert(delayedTransition.sourceID)
                self.delayedTransition = nil
            } else {
                delayedTransition.remainingReads -= 1
                self.delayedTransition = delayedTransition
            }
        }
        return selectedSourceID
    }

    func sourceState(for sourceID: String) -> InputSourceState? {
        states[sourceID]
    }

    func asciiCapableSourceStates() -> [InputSourceState] {
        states.values.filter(\.isASCIICapable)
    }

    func select(sourceID: String) -> OSStatus {
        operations.append("select:\(sourceID)")
        let status = selectionStatuses[sourceID] ?? noErr
        guard status == noErr else { return status }

        if let remainingReads = delayedTransitionReads.removeValue(forKey: sourceID) {
            delayedTransition = DelayedTransition(
                sourceID: sourceID,
                remainingReads: remainingReads
            )
            postSelectionNotification()
            return status
        }

        if selectedSourceID != sourceID {
            previousSourceID = selectedSourceID
            selectedSourceID = sourceID
            postSelectionNotification()
        }
        return status
    }

    func previousInputSourceShortcut() throws -> NativePreviousInputSourceShortcut {
        shortcutReadCount += 1
        return shortcut
    }

    func ensurePostEventAccess() -> PostEventPermissionState {
        permissionCheckCount += 1
        return permissionState
    }

    func postPreviousInputSourceShortcut(
        _ shortcut: NativePreviousInputSourceShortcut
    ) throws {
        operations.append("native-previous")
        onPost?(shortcut)
        guard !nativeTransitionIsStalled else {
            postSelectionNotification()
            return
        }
        let nextSourceID = previousSourceID
        previousSourceID = selectedSourceID
        selectedSourceID = nextSourceID
        postSelectionNotification()
    }

    private func postSelectionNotification() {
        notificationCenter.post(
            name: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil
        )
    }
}

@MainActor
private final class SlowFakeSelection: InputSourceSelecting {
    private(set) var startedTargets: [InputSourceSelectionTarget] = []
    private(set) var completedTargets: [InputSourceSelectionTarget] = []
    private(set) var maximumConcurrentSelections = 0
    private var concurrentSelections = 0

    func select(
        _ target: InputSourceSelectionTarget,
        isSuperseded: @escaping @MainActor () -> Bool
    ) async throws {
        concurrentSelections += 1
        maximumConcurrentSelections = max(
            maximumConcurrentSelections,
            concurrentSelections
        )
        startedTargets.append(target)
        defer { concurrentSelections -= 1 }

        try await Task.sleep(nanoseconds: 20_000_000)
        if isSuperseded() {
            throw SupersededInputSourceRequest()
        }
        completedTargets.append(target)
    }

    func consumeInternallyPostedShortcut(_ signature: ShortcutSignature) -> Bool {
        false
    }
}
