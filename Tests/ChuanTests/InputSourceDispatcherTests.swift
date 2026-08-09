import Carbon
import CoreGraphics
import Foundation
import Testing
@testable import chuan

private let layoutA = DispatchInputSource(
    id: "com.apple.keylayout.US",
    isKeyboardLayout: true
)
private let layoutBridge = DispatchInputSource(
    id: "com.apple.keylayout.ABC",
    isKeyboardLayout: true
)
private let methodB = DispatchInputSource(
    id: "com.apple.inputmethod.Japanese",
    isKeyboardLayout: false
)
private let previousSourceShortcut = NativePreviousInputSourceShortcut(
    keyCode: 49,
    eventFlags: .maskControl,
    signature: ShortcutSignature(
        keyCode: 49,
        carbonModifiers: controlKey
    )
)
private let afterSuppressionWindowNanoseconds: UInt64 = 1_000_000_001
private let verificationWaitNanoseconds: UInt64 = 150_000_000
private let latencyWarmupCount = 100
private let latencySampleCount = 1_000

private enum DispatchOperation: Equatable {
    case discoverBridge
    case readPreviousSourceShortcut
    case checkPostEventAccess
    case select(String)
    case nativeKeyDown
    case nativeKeyUp
}

@MainActor
private final class FakeInputSourceDispatchSystem: InputSourceDispatchSystem {
    var currentSourceID: String?
    var bridgeSources = [layoutBridge]
    var shortcutError: SymbolicHotKeyError?
    var shortcut = previousSourceShortcut
    var permission: PostEventPermissionState = .preflightGranted
    var selectionStatuses: [String: OSStatus] = [:]
    var operations: [DispatchOperation] = []
    var eventSourceStates: [CGEventSourceStateID] = []
    var eventMarkers: [Int64] = []
    var keyUpWasPostedOnMainThread = false

    private var previousSourceID: String?

    init(currentSourceID: String? = layoutA.id) {
        self.currentSourceID = currentSourceID
    }

    func asciiCapableKeyboardLayouts() -> [DispatchInputSource] {
        operations.append(.discoverBridge)
        return bridgeSources
    }

    func previousInputSourceShortcut() throws -> NativePreviousInputSourceShortcut {
        operations.append(.readPreviousSourceShortcut)
        if let shortcutError {
            throw shortcutError
        }
        return shortcut
    }

    func ensurePostEventAccess() -> PostEventPermissionState {
        operations.append(.checkPostEventAccess)
        return permission
    }

    func select(_ inputSource: DispatchInputSource) -> OSStatus {
        operations.append(.select(inputSource.id))
        let status = selectionStatuses[inputSource.id] ?? noErr
        if status == noErr {
            previousSourceID = currentSourceID
            currentSourceID = inputSource.id
        }
        return status
    }

    func postPreviousInputSourceShortcut(
        _ shortcut: NativePreviousInputSourceShortcut,
        eventSourceState: CGEventSourceStateID,
        marker: Int64,
        didPost: (NativeKeyEventPhase) -> Void
    ) throws {
        eventSourceStates.append(eventSourceState)
        eventMarkers.append(marker)
        operations.append(.nativeKeyDown)
        didPost(.keyDown)
        operations.append(.nativeKeyUp)
        keyUpWasPostedOnMainThread = Thread.isMainThread
        didPost(.keyUp)
        swap(&currentSourceID, &previousSourceID)
    }
}

@MainActor
private func makeSelector(
    system: FakeInputSourceDispatchSystem,
    now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
    diagnostics: @escaping (String) -> Void = { _ in },
    reportedErrors: @escaping (InputSourceDispatchError) -> Void = { _ in }
) -> InputSourceSelector {
    InputSourceSelector(
        system: system,
        monotonicNow: now,
        diagnostics: diagnostics,
        reportSetupFailure: reportedErrors
    )
}

@Test("An ordinary layout uses one checked TIS selection without PostEvent access")
@MainActor
func ordinaryLayoutUsesOneCheckedTISSelectionWithoutPostEventAccess() {
    let system = FakeInputSourceDispatchSystem()
    let selector = makeSelector(system: system)
    selector.prepare([layoutA], shortcutSignatures: [:])

    #expect(system.operations.isEmpty)
    let result = selector.dispatch(sourceID: layoutA.id, callbackEnteredAt: 1)

    #expect(result.error == nil)
    #expect(result.verification == nil)
    #expect(system.operations == [.select(layoutA.id)])
}

@Test("An ordinary layout reports its single failed TIS selection")
@MainActor
func ordinaryLayoutReportsItsSingleFailedTISSelection() {
    let system = FakeInputSourceDispatchSystem()
    system.selectionStatuses[layoutA.id] = OSStatus(paramErr)
    let selector = makeSelector(system: system)
    selector.prepare([layoutA], shortcutSignatures: [:])

    let result = selector.dispatch(sourceID: layoutA.id, callbackEnteredAt: 1)

    #expect(result.error == .selectionFailed(
        phase: "target",
        sourceID: layoutA.id,
        status: OSStatus(paramErr)
    ))
    #expect(system.operations == [.select(layoutA.id)])
}

@Test("A complex method dispatches target, ASCII bridge, native down, and native up in order")
@MainActor
func complexMethodDispatchesTheRequiredSequenceInOrder() throws {
    let system = FakeInputSourceDispatchSystem()
    var diagnosticsFollowedNativeKeyUp = true
    let selector = makeSelector(
        system: system,
        diagnostics: { _ in
            diagnosticsFollowedNativeKeyUp = diagnosticsFollowedNativeKeyUp
                && system.operations.last == .nativeKeyUp
        }
    )
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll()

    let result = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)

    #expect(result.error == nil)
    #expect(result.verification != nil)
    #expect(system.operations == [
        .select(methodB.id),
        .select(layoutBridge.id),
        .nativeKeyDown,
        .nativeKeyUp
    ])
    #expect(try #require(system.eventSourceStates.first) == .hidSystemState)
    #expect(system.eventMarkers == [InputSourceSelector.internalEventMarker])
    #expect(diagnosticsFollowedNativeKeyUp)
}

@Test("Native key-up is posted on the main thread before synchronous dispatch returns")
@MainActor
func nativeKeyUpIsPostedBeforeSynchronousDispatchReturns() {
    let system = FakeInputSourceDispatchSystem()
    let selector = makeSelector(system: system)
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll()

    let result = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)

    #expect(result.error == nil)
    #expect(system.keyUpWasPostedOnMainThread)
    #expect(system.operations.last == .nativeKeyUp)
}

@Test("An off-main shortcut callback synchronously enters the main thread")
func offMainShortcutCallbackSynchronouslyEntersTheMainThread() async {
    let ranOnMainThread = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            ShortcutRegistry.synchronouslyOnMainThread {
                continuation.resume(returning: Thread.isMainThread)
            }
        }
    }

    #expect(ranOnMainThread)
}

@Test("Complex dispatch performs no discovery, preference read, or permission request in the hot path")
@MainActor
func complexDispatchUsesOnlyPreparedStateBeforeNativePost() {
    let system = FakeInputSourceDispatchSystem()
    let selector = makeSelector(system: system)

    selector.prepare([methodB], shortcutSignatures: [:])
    #expect(system.operations == [
        .discoverBridge,
        .readPreviousSourceShortcut,
        .checkPostEventAccess
    ])
    system.operations.removeAll()

    _ = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)

    #expect(system.operations == [
        .select(methodB.id),
        .select(layoutBridge.id),
        .nativeKeyDown,
        .nativeKeyUp
    ])
}

@Test("A same-target complex request still performs the full handoff")
@MainActor
func sameTargetComplexRequestPerformsTheFullHandoff() {
    let system = FakeInputSourceDispatchSystem(currentSourceID: methodB.id)
    let selector = makeSelector(system: system)
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll()

    let result = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)

    #expect(result.error == nil)
    #expect(system.operations == [
        .select(methodB.id),
        .select(layoutBridge.id),
        .nativeKeyDown,
        .nativeKeyUp
    ])
    #expect(system.currentSourceID == methodB.id)
}

@Test("A failed target selection stops before bridge selection and native events")
@MainActor
func failedTargetSelectionStopsTheHandoff() {
    let system = FakeInputSourceDispatchSystem()
    system.selectionStatuses[methodB.id] = OSStatus(paramErr)
    let selector = makeSelector(system: system)
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll()

    let result = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)

    #expect(result.error == .selectionFailed(
        phase: "target",
        sourceID: methodB.id,
        status: OSStatus(paramErr)
    ))
    #expect(system.operations == [.select(methodB.id)])
}

@Test("A failed bridge selection stops before native events")
@MainActor
func failedBridgeSelectionStopsBeforeNativeEvents() {
    let system = FakeInputSourceDispatchSystem()
    system.selectionStatuses[layoutBridge.id] = OSStatus(paramErr)
    let selector = makeSelector(system: system)
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll()

    let result = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)

    #expect(result.error == .selectionFailed(
        phase: "bridge",
        sourceID: layoutBridge.id,
        status: OSStatus(paramErr)
    ))
    #expect(system.operations == [
        .select(methodB.id),
        .select(layoutBridge.id)
    ])
}

@Test("Missing, disabled, and malformed previous-source shortcuts are rejected")
func invalidPreviousSourceShortcutsAreRejected() {
    #expect(parseError(from: [:]) == .missing)
    #expect(parseError(from: symbolicHotKeyDomain(enabled: false)) == .disabled)

    let malformed: [String: Any] = [
        "AppleSymbolicHotKeys": [
            "60": ["enabled": true]
        ]
    ]
    #expect(parseError(from: malformed) == .malformed)
}

@Test("The previous-source shortcut parser preserves the key and converted modifiers")
func previousSourceShortcutParserPreservesKeyAndModifiers() throws {
    let flags: CGEventFlags = [.maskControl, .maskAlternate]
    let shortcut = try SymbolicHotKeyParser.previousInputSourceShortcut(
        from: symbolicHotKeyDomain(enabled: true, flags: flags)
    )

    #expect(shortcut.keyCode == 49)
    #expect(shortcut.eventFlags == flags)
    #expect(shortcut.signature == ShortcutSignature(
        keyCode: 49,
        carbonModifiers: controlKey | optionKey
    ))
}

@Test("Invalid previous-source shortcut setup reports once and never changes the input source")
@MainActor
func invalidShortcutSetupReportsOnceWithoutSelectingASource() {
    for shortcutError in [
        SymbolicHotKeyError.missing,
        .disabled,
        .malformed
    ] {
        let system = FakeInputSourceDispatchSystem()
        system.shortcutError = shortcutError
        var reportedErrors: [InputSourceDispatchError] = []
        let selector = makeSelector(
            system: system,
            reportedErrors: { reportedErrors.append($0) }
        )
        selector.prepare([methodB], shortcutSignatures: [:])
        system.operations.removeAll()

        let first = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)
        let second = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 2)

        #expect(first.error == .symbolicHotKey(shortcutError))
        #expect(second.error == .symbolicHotKey(shortcutError))
        #expect(reportedErrors == [.symbolicHotKey(shortcutError)])
        #expect(system.operations.isEmpty)
        #expect(system.currentSourceID == layoutA.id)
    }
}

@Test("An empty bridge discovery reports once and never changes the input source")
@MainActor
func emptyBridgeDiscoveryReportsOnceWithoutSelectingASource() {
    let system = FakeInputSourceDispatchSystem()
    system.bridgeSources = []
    var reportedErrors: [InputSourceDispatchError] = []
    let selector = makeSelector(
        system: system,
        reportedErrors: { reportedErrors.append($0) }
    )
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll()

    _ = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)
    _ = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 2)

    #expect(reportedErrors == [.noBridge])
    #expect(system.operations.isEmpty)
    #expect(system.currentSourceID == layoutA.id)
}

@Test("Denied PostEvent access reports once and never changes the input source")
@MainActor
func deniedPostEventAccessReportsOnceWithoutSelectingASource() {
    let system = FakeInputSourceDispatchSystem()
    system.permission = .denied
    var reportedErrors: [InputSourceDispatchError] = []
    let selector = makeSelector(
        system: system,
        reportedErrors: { reportedErrors.append($0) }
    )
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll()

    _ = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1)
    _ = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 2)

    #expect(reportedErrors == [.postEventPermissionDenied])
    #expect(system.operations.isEmpty)
    #expect(system.currentSourceID == layoutA.id)
}

@Test("Synthetic shortcut callbacks are suppressed without suppressing later physical callbacks")
@MainActor
func syntheticShortcutCallbacksCannotRecurse() {
    let system = FakeInputSourceDispatchSystem()
    var now: UInt64 = 10
    let selector = makeSelector(system: system, now: { now })
    selector.prepare(
        [layoutA, methodB],
        shortcutSignatures: [layoutA.id: previousSourceShortcut.signature]
    )

    _ = selector.dispatch(sourceID: methodB.id, callbackEnteredAt: now)

    #expect(!selector.shouldHandleShortcut(for: layoutA.id))
    now += afterSuppressionWindowNanoseconds
    #expect(selector.shouldHandleShortcut(for: layoutA.id))
}

@Test("A newer layout request supersedes the old verifier without restoring an old source")
@MainActor
func newerLayoutRequestInvalidatesOldVerificationWithoutRecoverySelection() throws {
    let system = FakeInputSourceDispatchSystem()
    let selector = makeSelector(system: system)
    selector.prepare([layoutA, methodB], shortcutSignatures: [:])
    let oldVerification = try #require(
        selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1).verification
    )
    system.operations.removeAll()

    let newerResult = selector.dispatch(sourceID: layoutA.id, callbackEnteredAt: 2)
    let oldOutcome = selector.verify(oldVerification)

    #expect(newerResult.error == nil)
    #expect(oldOutcome == .superseded)
    #expect(system.operations == [.select(layoutA.id)])
    #expect(system.currentSourceID == layoutA.id)
}

@Test("A stale verification schedule cannot cancel the newer verifier")
@MainActor
func staleVerificationScheduleCannotReplaceTheNewerVerifier() async throws {
    let system = FakeInputSourceDispatchSystem()
    var diagnostics: [String] = []
    let selector = makeSelector(
        system: system,
        diagnostics: { diagnostics.append($0) }
    )
    selector.prepare([methodB], shortcutSignatures: [:])
    let oldVerification = try #require(
        selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1).verification
    )
    let newVerification = try #require(
        selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 2).verification
    )
    diagnostics.removeAll()

    selector.scheduleVerification(newVerification)
    selector.scheduleVerification(oldVerification)
    try await Task.sleep(nanoseconds: verificationWaitNanoseconds)

    let verificationDiagnostics = diagnostics.filter { $0.contains("phase=verification") }
    #expect(verificationDiagnostics.count == 1)
    #expect(verificationDiagnostics.first?.contains("request=2") == true)
}

@Test("Verification logs a mismatch without retrying or changing the source")
@MainActor
func verificationMismatchDoesNotRetryOrChangeTheSource() throws {
    let system = FakeInputSourceDispatchSystem()
    var diagnostics: [String] = []
    let selector = makeSelector(
        system: system,
        diagnostics: { diagnostics.append($0) }
    )
    selector.prepare([methodB], shortcutSignatures: [:])
    let verification = try #require(
        selector.dispatch(sourceID: methodB.id, callbackEnteredAt: 1).verification
    )
    system.operations.removeAll()
    system.currentSourceID = layoutA.id

    let outcome = selector.verify(verification)

    #expect(outcome == .mismatch(currentID: layoutA.id))
    #expect(system.operations.isEmpty)
    #expect(diagnostics.contains { $0.contains("phase=verification") && $0.contains("outcome=mismatch") })
}

@Test("Warmed permission-granted release harness records callback-entry-to-key-up latency")
@MainActor
func warmedPermissionGrantedDispatchMeasuresNativeKeyUpLatency() throws {
    let system = FakeInputSourceDispatchSystem()
    let selector = makeSelector(system: system)
    selector.prepare([methodB], shortcutSignatures: [:])
    system.operations.removeAll(keepingCapacity: true)

    for _ in 0..<latencyWarmupCount {
        _ = selector.dispatch(
            sourceID: methodB.id,
            callbackEnteredAt: DispatchTime.now().uptimeNanoseconds
        )
        system.operations.removeAll(keepingCapacity: true)
    }

    var samples: [UInt64] = []
    samples.reserveCapacity(latencySampleCount)
    for _ in 0..<latencySampleCount {
        let result = selector.dispatch(
            sourceID: methodB.id,
            callbackEnteredAt: DispatchTime.now().uptimeNanoseconds
        )
        samples.append(try #require(result.callbackToNativeKeyUpNanoseconds))
        system.operations.removeAll(keepingCapacity: true)
    }
    samples.sort()
    let median = samples[samples.count / 2]
    let percentile95 = samples[(samples.count * 95) / 100]

    print(
        "callback_entry_to_native_key_up_ns median=\(median) "
            + "p95=\(percentile95) samples=\(samples.count) "
            + "permission=preflightGranted system=test-double"
    )
    #expect(median > 0)
}

private func parseError(from domain: [String: Any]) -> SymbolicHotKeyError? {
    do {
        _ = try SymbolicHotKeyParser.previousInputSourceShortcut(from: domain)
        return nil
    } catch let error as SymbolicHotKeyError {
        return error
    } catch {
        return .malformed
    }
}

private func symbolicHotKeyDomain(
    enabled: Bool,
    flags: CGEventFlags = .maskControl
) -> [String: Any] {
    [
        "AppleSymbolicHotKeys": [
            "60": [
                "enabled": enabled,
                "value": [
                    "parameters": [0, 49, flags.rawValue]
                ]
            ]
        ]
    ]
}
