import AppKit
import Carbon
import CoreGraphics
import Foundation
import OSLog

struct DispatchInputSource: Equatable {
    let id: String
    let isKeyboardLayout: Bool
    fileprivate let tisInputSource: TISInputSource?

    init(_ inputSource: InputSource) {
        id = inputSource.id
        isKeyboardLayout = inputSource.source.inputSourceType == kTISTypeKeyboardLayout as String
        tisInputSource = inputSource.source
    }

    init(id: String, isKeyboardLayout: Bool) {
        self.id = id
        self.isKeyboardLayout = isKeyboardLayout
        tisInputSource = nil
    }

    fileprivate init?(tisInputSource: TISInputSource) {
        guard let id = tisInputSource.identifier else { return nil }
        self.id = id
        isKeyboardLayout = tisInputSource.inputSourceType == kTISTypeKeyboardLayout as String
        self.tisInputSource = tisInputSource
    }

    static func == (lhs: DispatchInputSource, rhs: DispatchInputSource) -> Bool {
        lhs.id == rhs.id && lhs.isKeyboardLayout == rhs.isKeyboardLayout
    }
}

struct ShortcutSignature: Equatable, Hashable {
    let keyCode: Int
    let carbonModifiers: Int
}

struct NativePreviousInputSourceShortcut: Equatable {
    let keyCode: CGKeyCode
    let eventFlags: CGEventFlags
    let signature: ShortcutSignature
}

enum SymbolicHotKeyError: LocalizedError, Equatable {
    case missing
    case disabled
    case malformed

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The macOS Select the previous input source shortcut is unavailable."
        case .disabled:
            return "Enable Select the previous input source in System Settings > Keyboard > Keyboard Shortcuts > Input Sources."
        case .malformed:
            return "The macOS Select the previous input source shortcut has an unsupported configuration."
        }
    }
}

enum SymbolicHotKeyParser {
    private static let previousInputSourceEntryID = "60"
    private static let keyCodeParameterIndex = 1
    private static let modifierParameterIndex = 2

    static func previousInputSourceShortcut(
        from domain: [String: Any]
    ) throws -> NativePreviousInputSourceShortcut {
        guard let entries = domain["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = entries[previousInputSourceEntryID] as? [String: Any] else {
            throw SymbolicHotKeyError.missing
        }
        guard let enabled = entry["enabled"] as? NSNumber else {
            throw SymbolicHotKeyError.malformed
        }
        guard enabled.boolValue else {
            throw SymbolicHotKeyError.disabled
        }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.indices.contains(modifierParameterIndex),
              let keyCodeNumber = parameters[keyCodeParameterIndex] as? NSNumber,
              let modifierNumber = parameters[modifierParameterIndex] as? NSNumber,
              keyCodeNumber.intValue >= 0,
              keyCodeNumber.intValue <= Int(UInt16.max) else {
            throw SymbolicHotKeyError.malformed
        }

        let eventFlags = CGEventFlags(rawValue: modifierNumber.uint64Value)
        return NativePreviousInputSourceShortcut(
            keyCode: CGKeyCode(keyCodeNumber.intValue),
            eventFlags: eventFlags,
            signature: ShortcutSignature(
                keyCode: keyCodeNumber.intValue,
                carbonModifiers: carbonModifiers(from: eventFlags)
            )
        )
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> Int {
        var modifiers = 0
        if flags.contains(.maskCommand) {
            modifiers |= cmdKey
        }
        if flags.contains(.maskControl) {
            modifiers |= controlKey
        }
        if flags.contains(.maskAlternate) {
            modifiers |= optionKey
        }
        if flags.contains(.maskShift) {
            modifiers |= shiftKey
        }
        return modifiers
    }
}

enum PostEventPermissionState: String, Equatable {
    case preflightGranted
    case requestGranted
    case denied

    var isGranted: Bool {
        self != .denied
    }
}

struct PostEventAccessController {
    private var hasRequestedAccess = false

    mutating func ensureAccess(
        preflight: () -> Bool,
        request: () -> Bool
    ) -> PostEventPermissionState {
        if preflight() {
            return .preflightGranted
        }
        guard !hasRequestedAccess else { return .denied }
        hasRequestedAccess = true
        return request() ? .requestGranted : .denied
    }
}

enum InputSourceDispatchError: LocalizedError, Equatable {
    case targetUnavailable(String)
    case noBridge
    case symbolicHotKey(SymbolicHotKeyError)
    case postEventPermissionDenied
    case selectionFailed(phase: String, sourceID: String, status: OSStatus)
    case nativeEventCreationFailed

    var errorDescription: String? {
        switch self {
        case let .targetUnavailable(sourceID):
            return "Input source \(sourceID) is not prepared. Refresh input sources and try again."
        case .noBridge:
            return "No enabled ASCII keyboard layout is available for complex input-method switching."
        case let .symbolicHotKey(error):
            return error.localizedDescription
        case .postEventPermissionDenied:
            return "Chuan needs permission to use the macOS input-source shortcut. Open System Settings > Privacy & Security > Accessibility, enable Chuan, then quit and reopen Chuan."
        case let .selectionFailed(phase, sourceID, status):
            return "Could not select input source \(sourceID) during \(phase) (TIS status \(status))."
        case .nativeEventCreationFailed:
            return "Chuan could not create the macOS previous-input-source events."
        }
    }
}

enum NativeKeyEventPhase {
    case keyDown
    case keyUp
}

@MainActor
protocol InputSourceDispatchSystem: AnyObject {
    var currentSourceID: String? { get }

    func asciiCapableKeyboardLayouts() -> [DispatchInputSource]
    func previousInputSourceShortcut() throws -> NativePreviousInputSourceShortcut
    func ensurePostEventAccess() -> PostEventPermissionState
    func select(_ inputSource: DispatchInputSource) -> OSStatus
    func postPreviousInputSourceShortcut(
        _ shortcut: NativePreviousInputSourceShortcut,
        eventSourceState: CGEventSourceStateID,
        marker: Int64,
        didPost: (NativeKeyEventPhase) -> Void
    ) throws
}

@MainActor
final class LiveInputSourceDispatchSystem: InputSourceDispatchSystem {
    private var postEventAccess = PostEventAccessController()

    var currentSourceID: String? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue().identifier
    }

    func asciiCapableKeyboardLayouts() -> [DispatchInputSource] {
        guard let list = TISCreateASCIICapableInputSourceList() else {
            return []
        }
        let sources = (list.takeRetainedValue() as NSArray) as? [TISInputSource] ?? []
        return sources
            .filter {
                $0.inputSourceType == kTISTypeKeyboardLayout as String
                    && $0.isEnabled
                    && $0.isSelectable
                    && $0.isASCIICapable
            }
            .compactMap(DispatchInputSource.init)
            .sorted { $0.id < $1.id }
    }

    func previousInputSourceShortcut() throws -> NativePreviousInputSourceShortcut {
        let domain = UserDefaults.standard.persistentDomain(
            forName: "com.apple.symbolichotkeys"
        ) ?? [:]
        return try SymbolicHotKeyParser.previousInputSourceShortcut(from: domain)
    }

    func ensurePostEventAccess() -> PostEventPermissionState {
        postEventAccess.ensureAccess(
            preflight: { CGPreflightPostEventAccess() },
            request: { CGRequestPostEventAccess() }
        )
    }

    func select(_ inputSource: DispatchInputSource) -> OSStatus {
        guard let tisInputSource = inputSource.tisInputSource else {
            return OSStatus(paramErr)
        }
        return TISSelectInputSource(tisInputSource)
    }

    func postPreviousInputSourceShortcut(
        _ shortcut: NativePreviousInputSourceShortcut,
        eventSourceState: CGEventSourceStateID,
        marker: Int64,
        didPost: (NativeKeyEventPhase) -> Void
    ) throws {
        guard let source = CGEventSource(stateID: eventSourceState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: shortcut.keyCode,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: shortcut.keyCode,
                keyDown: false
              ) else {
            throw InputSourceDispatchError.nativeEventCreationFailed
        }

        keyDown.flags = shortcut.eventFlags
        keyDown.setIntegerValueField(.eventSourceUserData, value: marker)
        keyUp.flags = shortcut.eventFlags
        keyUp.setIntegerValueField(.eventSourceUserData, value: marker)

        keyDown.post(tap: .cghidEventTap)
        didPost(.keyDown)
        keyUp.post(tap: .cghidEventTap)
        didPost(.keyUp)
    }
}

struct PostDispatchVerification: Equatable {
    let requestID: UInt64
    let targetID: String
    let callbackEnteredAt: UInt64
}

enum PostDispatchVerificationOutcome: Equatable {
    case current
    case superseded
    case mismatch(currentID: String?)
}

struct SynchronousDispatchResult {
    let error: InputSourceDispatchError?
    let verification: PostDispatchVerification?
    let callbackToNativeKeyUpNanoseconds: UInt64?

    init(
        error: InputSourceDispatchError? = nil,
        verification: PostDispatchVerification? = nil,
        callbackToNativeKeyUpNanoseconds: UInt64? = nil
    ) {
        self.error = error
        self.verification = verification
        self.callbackToNativeKeyUpNanoseconds = callbackToNativeKeyUpNanoseconds
    }
}

@MainActor
final class InputSourceSelector {
    private struct ComplexDispatchConfiguration {
        let target: DispatchInputSource
        let bridge: DispatchInputSource
        let shortcut: NativePreviousInputSourceShortcut
        let permission: PostEventPermissionState
    }

    private enum PreparedTarget {
        case ordinary(DispatchInputSource)
        case complex(Result<ComplexDispatchConfiguration, InputSourceDispatchError>)
    }

    private struct TimedPhase {
        let name: String
        let observedAt: UInt64
        let status: OSStatus?
        let outcome: String
    }

    static let shared = InputSourceSelector()
    static let internalEventMarker: Int64 = 0x436875616E

    private static let logger = Logger(
        subsystem: "com.chuan.Chuan",
        category: "InputSourceDispatch"
    )
    // Carbon can deliver the posted shortcut callback after the native post returns.
    private static let suppressionDurationNanoseconds: UInt64 = 1_000_000_000
    // Verification runs later so it cannot delay the native key events.
    private static let verificationDelayNanoseconds: UInt64 = 100_000_000

    private let system: InputSourceDispatchSystem
    private let monotonicNow: () -> UInt64
    private let diagnosticSink: ((String) -> Void)?
    private let setupFailureReporter: ((InputSourceDispatchError) -> Void)?
    private var preparedTargets: [String: PreparedTarget] = [:]
    private var shortcutSignatures: [String: ShortcutSignature] = [:]
    private var shortcutSuppressions: [ShortcutSignature: UInt64] = [:]
    private var reportedSetupFailures = Set<String>()
    private var latestRequestID: UInt64 = 0
    private var verificationTask: Task<Void, Never>?

    init(
        system: InputSourceDispatchSystem? = nil,
        monotonicNow: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        diagnostics: ((String) -> Void)? = nil,
        reportSetupFailure: ((InputSourceDispatchError) -> Void)? = nil
    ) {
        self.system = system ?? LiveInputSourceDispatchSystem()
        self.monotonicNow = monotonicNow
        diagnosticSink = diagnostics
        setupFailureReporter = reportSetupFailure
    }

    func prepare(
        _ inputSources: [DispatchInputSource],
        shortcutSignatures: [String: ShortcutSignature]
    ) {
        preparedTargets = [:]
        self.shortcutSignatures = shortcutSignatures
        reportedSetupFailures.removeAll()

        let complexTargets = inputSources.filter { !$0.isKeyboardLayout }
        for target in inputSources where target.isKeyboardLayout {
            preparedTargets[target.id] = .ordinary(target)
        }
        guard !complexTargets.isEmpty else { return }

        let setup: Result<(
            bridge: DispatchInputSource,
            shortcut: NativePreviousInputSourceShortcut,
            permission: PostEventPermissionState
        ), InputSourceDispatchError>
        do {
            guard let bridge = system.asciiCapableKeyboardLayouts().first else {
                throw InputSourceDispatchError.noBridge
            }
            let shortcut: NativePreviousInputSourceShortcut
            do {
                shortcut = try system.previousInputSourceShortcut()
            } catch let error as SymbolicHotKeyError {
                throw InputSourceDispatchError.symbolicHotKey(error)
            }
            let permission = system.ensurePostEventAccess()
            guard permission.isGranted else {
                throw InputSourceDispatchError.postEventPermissionDenied
            }
            setup = .success((bridge, shortcut, permission))
        } catch let error as InputSourceDispatchError {
            setup = .failure(error)
        } catch {
            setup = .failure(.symbolicHotKey(.malformed))
        }

        for target in complexTargets {
            switch setup {
            case let .success(setup):
                preparedTargets[target.id] = .complex(.success(
                    ComplexDispatchConfiguration(
                        target: target,
                        bridge: setup.bridge,
                        shortcut: setup.shortcut,
                        permission: setup.permission
                    )
                ))
            case let .failure(error):
                preparedTargets[target.id] = .complex(.failure(error))
            }
        }
    }

    func updateShortcutSignature(
        _ signature: ShortcutSignature?,
        for sourceID: String
    ) {
        shortcutSignatures[sourceID] = signature
    }

    func shouldHandleShortcut(for sourceID: String) -> Bool {
        let now = monotonicNow()
        shortcutSuppressions = shortcutSuppressions.filter { $0.value > now }
        guard let signature = shortcutSignatures[sourceID] else { return true }
        return shortcutSuppressions[signature] == nil
    }

    func dispatch(
        sourceID: String,
        callbackEnteredAt: UInt64
    ) -> SynchronousDispatchResult {
        precondition(Thread.isMainThread, "Input-source dispatch must execute on the main thread")
        verificationTask?.cancel()
        verificationTask = nil
        latestRequestID &+= 1
        let requestID = latestRequestID

        guard let preparedTarget = preparedTargets[sourceID] else {
            let error = InputSourceDispatchError.targetUnavailable(sourceID)
            reportDispatch(
                requestID: requestID,
                targetID: sourceID,
                callbackEnteredAt: callbackEnteredAt,
                callbackOutcome: "setup-error"
            )
            reportSetupFailureOnce(error, for: sourceID)
            return SynchronousDispatchResult(error: error)
        }

        switch preparedTarget {
        case let .ordinary(target):
            let status = system.select(target)
            reportDispatch(
                requestID: requestID,
                targetID: target.id,
                callbackEnteredAt: callbackEnteredAt,
                phases: [TimedPhase(
                    name: "target-tis",
                    observedAt: monotonicNow(),
                    status: status,
                    outcome: status == noErr ? "complete" : "error"
                )]
            )
            guard status != noErr else { return SynchronousDispatchResult() }
            return SynchronousDispatchResult(error: .selectionFailed(
                phase: "target",
                sourceID: target.id,
                status: status
            ))

        case let .complex(.failure(error)):
            reportDispatch(
                requestID: requestID,
                targetID: sourceID,
                callbackEnteredAt: callbackEnteredAt,
                callbackOutcome: "setup-error"
            )
            reportSetupFailureOnce(error, for: sourceID)
            return SynchronousDispatchResult(error: error)

        case let .complex(.success(configuration)):
            return dispatchComplexInputMethod(
                configuration,
                requestID: requestID,
                callbackEnteredAt: callbackEnteredAt
            )
        }
    }

    @discardableResult
    func scheduleVerification(_ verification: PostDispatchVerification) -> Bool {
        guard verification.requestID == latestRequestID else { return false }
        verificationTask?.cancel()
        verificationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.verificationDelayNanoseconds)
            guard !Task.isCancelled else { return }
            _ = self?.verify(verification)
        }
        return true
    }

    @discardableResult
    func verify(
        _ verification: PostDispatchVerification
    ) -> PostDispatchVerificationOutcome {
        guard verification.requestID == latestRequestID else {
            diagnostic(
                requestID: verification.requestID,
                phase: "verification",
                targetID: verification.targetID,
                callbackEnteredAt: verification.callbackEnteredAt,
                observedAt: monotonicNow(),
                status: nil,
                outcome: "superseded"
            )
            return .superseded
        }

        let currentSourceID = system.currentSourceID
        let outcome: PostDispatchVerificationOutcome = currentSourceID == verification.targetID
            ? .current
            : .mismatch(currentID: currentSourceID)
        diagnostic(
            requestID: verification.requestID,
            phase: "verification",
            targetID: verification.targetID,
            callbackEnteredAt: verification.callbackEnteredAt,
            observedAt: monotonicNow(),
            status: nil,
            outcome: currentSourceID == verification.targetID ? "complete" : "mismatch",
            currentSourceID: currentSourceID
        )
        return outcome
    }

    private func dispatchComplexInputMethod(
        _ configuration: ComplexDispatchConfiguration,
        requestID: UInt64,
        callbackEnteredAt: UInt64
    ) -> SynchronousDispatchResult {
        let targetStatus = system.select(configuration.target)
        let targetReturnedAt = monotonicNow()
        let targetPhase = TimedPhase(
            name: "target-tis",
            observedAt: targetReturnedAt,
            status: targetStatus,
            outcome: targetStatus == noErr ? "complete" : "error"
        )
        guard targetStatus == noErr else {
            reportDispatch(
                requestID: requestID,
                targetID: configuration.target.id,
                callbackEnteredAt: callbackEnteredAt,
                phases: [targetPhase],
                permission: configuration.permission
            )
            return SynchronousDispatchResult(error: .selectionFailed(
                phase: "target",
                sourceID: configuration.target.id,
                status: targetStatus
            ))
        }

        let bridgeStatus = system.select(configuration.bridge)
        let bridgeReturnedAt = monotonicNow()
        let bridgePhase = TimedPhase(
            name: "bridge-tis",
            observedAt: bridgeReturnedAt,
            status: bridgeStatus,
            outcome: bridgeStatus == noErr ? "complete" : "error"
        )
        guard bridgeStatus == noErr else {
            reportDispatch(
                requestID: requestID,
                targetID: configuration.target.id,
                callbackEnteredAt: callbackEnteredAt,
                phases: [targetPhase, bridgePhase],
                permission: configuration.permission
            )
            return SynchronousDispatchResult(error: .selectionFailed(
                phase: "bridge",
                sourceID: configuration.bridge.id,
                status: bridgeStatus
            ))
        }

        shortcutSuppressions[configuration.shortcut.signature] =
            monotonicNow() &+ Self.suppressionDurationNanoseconds
        var keyDownPostedAt: UInt64?
        var keyUpPostedAt: UInt64?
        do {
            try system.postPreviousInputSourceShortcut(
                configuration.shortcut,
                eventSourceState: .hidSystemState,
                marker: Self.internalEventMarker
            ) { phase in
                switch phase {
                case .keyDown:
                    keyDownPostedAt = monotonicNow()
                case .keyUp:
                    keyUpPostedAt = monotonicNow()
                }
            }
        } catch {
            let dispatchError = error as? InputSourceDispatchError
                ?? .nativeEventCreationFailed
            reportDispatch(
                requestID: requestID,
                targetID: configuration.target.id,
                callbackEnteredAt: callbackEnteredAt,
                phases: [
                    targetPhase,
                    bridgePhase,
                    TimedPhase(
                        name: "native-events",
                        observedAt: monotonicNow(),
                        status: nil,
                        outcome: "error"
                    )
                ],
                permission: configuration.permission
            )
            return SynchronousDispatchResult(error: dispatchError)
        }

        guard let keyDownPostedAt, let keyUpPostedAt else {
            return SynchronousDispatchResult(error: .nativeEventCreationFailed)
        }
        reportDispatch(
            requestID: requestID,
            targetID: configuration.target.id,
            callbackEnteredAt: callbackEnteredAt,
            phases: [
                targetPhase,
                bridgePhase,
                TimedPhase(
                    name: "native-key-down",
                    observedAt: keyDownPostedAt,
                    status: nil,
                    outcome: "posted"
                ),
                TimedPhase(
                    name: "native-key-up",
                    observedAt: keyUpPostedAt,
                    status: nil,
                    outcome: "posted"
                )
            ],
            permission: configuration.permission
        )
        return SynchronousDispatchResult(
            verification: PostDispatchVerification(
                requestID: requestID,
                targetID: configuration.target.id,
                callbackEnteredAt: callbackEnteredAt
            ),
            callbackToNativeKeyUpNanoseconds: elapsedNanoseconds(
                since: callbackEnteredAt,
                now: keyUpPostedAt
            )
        )
    }

    private func reportDispatch(
        requestID: UInt64,
        targetID: String,
        callbackEnteredAt: UInt64,
        callbackOutcome: String = "started",
        phases: [TimedPhase] = [],
        permission: PostEventPermissionState? = nil
    ) {
        diagnostic(
            requestID: requestID,
            phase: "callback-entry",
            targetID: targetID,
            callbackEnteredAt: callbackEnteredAt,
            observedAt: callbackEnteredAt,
            status: nil,
            outcome: callbackOutcome,
            permission: permission
        )
        for phase in phases {
            diagnostic(
                requestID: requestID,
                phase: phase.name,
                targetID: targetID,
                callbackEnteredAt: callbackEnteredAt,
                observedAt: phase.observedAt,
                status: phase.status,
                outcome: phase.outcome,
                permission: permission
            )
        }
    }

    private func reportSetupFailureOnce(
        _ error: InputSourceDispatchError,
        for sourceID: String
    ) {
        let failureKey = error.localizedDescription
        guard reportedSetupFailures.insert(failureKey).inserted else { return }
        emitDiagnostic(
            "phase=setup target=\(sourceID) elapsed_ns=0 status=n/a "
                + "outcome=error reason=\(error.localizedDescription)"
        )
        if let setupFailureReporter {
            setupFailureReporter(error)
        } else {
            Self.presentSetupFailure(error)
        }
    }

    private func diagnostic(
        requestID: UInt64,
        phase: String,
        targetID: String,
        callbackEnteredAt: UInt64,
        observedAt: UInt64,
        status: OSStatus?,
        outcome: String,
        currentSourceID: String? = nil,
        permission: PostEventPermissionState? = nil
    ) {
        emitDiagnostic(
            "request=\(requestID) phase=\(phase) target=\(targetID) "
                + "current=\(currentSourceID ?? "not-checked") "
                + "elapsed_ns=\(elapsedNanoseconds(since: callbackEnteredAt, now: observedAt)) "
                + "status=\(status.map(String.init) ?? "n/a") "
                + "permission=\(permission?.rawValue ?? "n/a") outcome=\(outcome)"
        )
    }

    private func emitDiagnostic(_ message: String) {
        if let diagnosticSink {
            diagnosticSink(message)
        } else {
            Self.logger.notice("\(message, privacy: .public)")
        }
    }

    private func elapsedNanoseconds(since start: UInt64, now: UInt64) -> UInt64 {
        now >= start ? now - start : 0
    }

    private static func presentSetupFailure(_ error: InputSourceDispatchError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Input-source setup is incomplete"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }
}
