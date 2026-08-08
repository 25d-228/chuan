import AppKit
import Carbon
import CoreGraphics
import Foundation
import KeyboardShortcuts

struct InputSourceSelectionTarget: Equatable, Sendable {
    let id: String
    let isKeyboardLayout: Bool

    init(_ inputSource: InputSource) {
        id = inputSource.id
        isKeyboardLayout = inputSource.source.inputSourceType == kTISTypeKeyboardLayout as String
    }

    init(id: String, isKeyboardLayout: Bool) {
        self.id = id
        self.isKeyboardLayout = isKeyboardLayout
    }
}

struct InputSourceState: Equatable, Sendable {
    let id: String
    let isKeyboardLayout: Bool
    let isASCIICapable: Bool
    let isEnabled: Bool
    let isSelectable: Bool

    var isSafeBridge: Bool {
        isKeyboardLayout && isASCIICapable && isEnabled && isSelectable
    }
}

struct ShortcutSignature: Equatable, Sendable {
    let keyCode: Int
    let carbonModifiers: Int
}

struct NativePreviousInputSourceShortcut: Equatable, Sendable {
    let keyCode: CGKeyCode
    let eventFlagsRawValue: UInt64
    let carbonModifiers: Int

    var eventFlags: CGEventFlags {
        CGEventFlags(rawValue: eventFlagsRawValue)
    }

    var signature: ShortcutSignature {
        ShortcutSignature(keyCode: Int(keyCode), carbonModifiers: carbonModifiers)
    }
}

enum SymbolicHotKeyError: LocalizedError, Equatable {
    case missing
    case disabled
    case malformed

    var errorDescription: String? {
        switch self {
        case .missing, .disabled:
            return "The macOS ‘Select the previous input source’ shortcut is disabled. Enable it in System Settings > Keyboard > Keyboard Shortcuts > Input Sources."
        case .malformed:
            return "The macOS ‘Select the previous input source’ shortcut could not be read. Reset it in System Settings > Keyboard > Keyboard Shortcuts > Input Sources."
        }
    }
}

enum SymbolicHotKeyParser {
    private static let supportedEventFlags: [CGEventFlags] = [
        .maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
        .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn
    ]

    static func previousInputSourceShortcut(
        from persistentDomain: [String: Any]?
    ) throws -> NativePreviousInputSourceShortcut {
        guard let persistentDomain,
              let hotKeys = persistentDomain["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = hotKeys["60"] as? [String: Any] else {
            throw SymbolicHotKeyError.missing
        }
        guard entry["enabled"] as? Bool == true else {
            throw SymbolicHotKeyError.disabled
        }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCodeValue = integerValue(parameters[1]),
              (0...Int64(UInt16.max)).contains(keyCodeValue),
              let modifierValue = integerValue(parameters[2]),
              modifierValue >= 0 else {
            throw SymbolicHotKeyError.malformed
        }

        let storedModifierMask = UInt64(modifierValue)
        var eventFlags: CGEventFlags = []
        var knownModifierMask: UInt64 = 0
        for flag in supportedEventFlags {
            knownModifierMask |= flag.rawValue
            if storedModifierMask & flag.rawValue != 0 {
                eventFlags.insert(flag)
            }
        }
        guard storedModifierMask & ~knownModifierMask == 0 else {
            throw SymbolicHotKeyError.malformed
        }

        var carbonModifiers = 0
        if eventFlags.contains(.maskCommand) { carbonModifiers |= cmdKey }
        if eventFlags.contains(.maskShift) { carbonModifiers |= shiftKey }
        if eventFlags.contains(.maskAlternate) { carbonModifiers |= optionKey }
        if eventFlags.contains(.maskControl) { carbonModifiers |= controlKey }

        return NativePreviousInputSourceShortcut(
            keyCode: CGKeyCode(keyCodeValue),
            eventFlagsRawValue: eventFlags.rawValue,
            carbonModifiers: carbonModifiers
        )
    }

    private static func integerValue(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let integer = number.int64Value
        guard number.doubleValue == Double(integer) else { return nil }
        return integer
    }
}

enum PostEventPermissionState: String, Equatable, Sendable {
    case preflightGranted = "preflight-granted"
    case requestGranted = "request-granted"
    case denied

    var isGranted: Bool {
        self != .denied
    }
}

struct PostEventAccessController {
    private(set) var hasRequestedAccess = false

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

enum InputSourceHandoffError: LocalizedError {
    case noBridge(String)
    case selectionFailed(phase: String, sourceID: String, status: OSStatus)
    case transitionTimedOut(phase: String, expectedID: String, currentID: String?)
    case shortcutReleaseTimedOut
    case postEventPermissionDenied
    case eventCreationFailed
    case sourceChangedDuringSettle(expectedID: String, currentID: String?)

    var errorDescription: String? {
        switch self {
        case let .noBridge(sourceID):
            return "Could not activate \(sourceID) because no enabled ASCII keyboard layout is available as a bridge."
        case let .selectionFailed(phase, sourceID, status):
            return "Could not select input source \(sourceID) during \(phase) (TIS status \(status))."
        case let .transitionTimedOut(phase, expectedID, currentID):
            return "Input-source handoff timed out during \(phase): expected \(expectedID), current \(currentID ?? "unknown")."
        case .shortcutReleaseTimedOut:
            return "Input-source handoff stopped because the shortcut modifiers remained held. Release Command, Control, Option, and Shift, then try again."
        case .postEventPermissionDenied:
            return "Chuan needs permission to use the macOS input-source shortcut. Open System Settings > Privacy & Security > Accessibility, enable Chuan, then quit and reopen Chuan."
        case .eventCreationFailed:
            return "Chuan could not create the native input-source shortcut event."
        case let .sourceChangedDuringSettle(expectedID, currentID):
            return "Input source changed while \(expectedID) was settling; current source is \(currentID ?? "unknown")."
        }
    }
}

@MainActor
protocol InputSourceHandoffSystem: AnyObject {
    var shortcutModifierFlags: NSEvent.ModifierFlags { get }
    var currentSourceID: String? { get }

    func sourceState(for sourceID: String) -> InputSourceState?
    func asciiCapableSourceStates() -> [InputSourceState]
    func select(sourceID: String) -> OSStatus
    func previousInputSourceShortcut() throws -> NativePreviousInputSourceShortcut
    func ensurePostEventAccess() -> PostEventPermissionState
    func postPreviousInputSourceShortcut(_ shortcut: NativePreviousInputSourceShortcut) throws
}

@MainActor
final class LiveInputSourceHandoffSystem: InputSourceHandoffSystem {
    private static let postedEventMarker: Int64 = 0x436875616E
    private var postEventAccess = PostEventAccessController()

    var shortcutModifierFlags: NSEvent.ModifierFlags {
        NSEvent.modifierFlags
    }

    var currentSourceID: String? {
        TISCopyCurrentKeyboardInputSource()?.takeRetainedValue().identifier
    }

    func sourceState(for sourceID: String) -> InputSourceState? {
        allInputSources()
            .first { $0.identifier == sourceID }
            .flatMap(InputSourceState.init)
    }

    func asciiCapableSourceStates() -> [InputSourceState] {
        let list = TISCreateASCIICapableInputSourceList().takeRetainedValue()
        return ((list as NSArray) as? [TISInputSource] ?? [])
            .compactMap(InputSourceState.init)
    }

    func select(sourceID: String) -> OSStatus {
        guard let source = allInputSources().first(where: { $0.identifier == sourceID }) else {
            return OSStatus(paramErr)
        }
        return TISSelectInputSource(source)
    }

    func previousInputSourceShortcut() throws -> NativePreviousInputSourceShortcut {
        try SymbolicHotKeyParser.previousInputSourceShortcut(
            from: UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")
        )
    }

    func ensurePostEventAccess() -> PostEventPermissionState {
        postEventAccess.ensureAccess(
            preflight: { CGPreflightPostEventAccess() },
            request: { CGRequestPostEventAccess() }
        )
    }

    func postPreviousInputSourceShortcut(
        _ shortcut: NativePreviousInputSourceShortcut
    ) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState),
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
            throw InputSourceHandoffError.eventCreationFailed
        }

        for event in [keyDown, keyUp] {
            event.flags = shortcut.eventFlags
            event.setIntegerValueField(
                .eventSourceUserData,
                value: Self.postedEventMarker
            )
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func allInputSources() -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else {
            return []
        }
        return (list as NSArray) as? [TISInputSource] ?? []
    }
}

private extension InputSourceState {
    init?(source: TISInputSource) {
        guard let id = source.identifier else { return nil }
        self.init(
            id: id,
            isKeyboardLayout: source.inputSourceType == kTISTypeKeyboardLayout as String,
            isASCIICapable: source.isASCIICapable,
            isEnabled: source.isEnabled,
            isSelectable: source.isSelectable
        )
    }
}

final class InputSourceChangeObservation {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?
    private(set) var notificationCount = 0

    init(center: NotificationCenter) {
        self.center = center
        token = center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notificationCount += 1
        }
    }

    func stop() {
        guard let token else { return }
        center.removeObserver(token)
        self.token = nil
    }

    deinit {
        stop()
    }
}

struct SupersededInputSourceRequest: Error {}

@MainActor
protocol InputSourceSelecting: AnyObject {
    func select(
        _ target: InputSourceSelectionTarget,
        isSuperseded: @escaping @MainActor () -> Bool
    ) async throws
    func isInternallyPosting(_ signature: ShortcutSignature) -> Bool
}

@MainActor
final class NativeInputSourceHandoff: InputSourceSelecting {
    private static let shortcutModifiers: NSEvent.ModifierFlags = [
        .command, .control, .option, .shift
    ]

    private let system: InputSourceHandoffSystem
    private let notificationCenter: NotificationCenter
    private let phaseTimeout: TimeInterval
    private let diagnostics: (String) -> Void
    private var postedShortcutSignature: ShortcutSignature?

    init(
        system: InputSourceHandoffSystem? = nil,
        notificationCenter: NotificationCenter = .default,
        phaseTimeout: TimeInterval = 1,
        diagnostics: @escaping (String) -> Void = {
            NSLog("Input-source handoff: %@", $0)
        }
    ) {
        self.system = system ?? LiveInputSourceHandoffSystem()
        self.notificationCenter = notificationCenter
        self.phaseTimeout = phaseTimeout
        self.diagnostics = diagnostics
    }

    func select(
        _ target: InputSourceSelectionTarget,
        isSuperseded: @escaping @MainActor () -> Bool
    ) async throws {
        if target.isKeyboardLayout {
            try selectKeyboardLayout(target)
            return
        }

        try await waitForShortcutRelease()
        await yieldMainRunLoop()
        try throwIfSuperseded(isSuperseded)

        let shortcut: NativePreviousInputSourceShortcut
        do {
            shortcut = try system.previousInputSourceShortcut()
        } catch {
            diagnostics(
                "phase=shortcut-config target=\(target.id) " +
                "current=\(system.currentSourceID ?? "unknown") elapsed_ms=0 timeout_ms=0 " +
                "permission=not-checked status=n/a outcome=error"
            )
            throw error
        }
        let permission = system.ensurePostEventAccess()
        diagnostics(
            "phase=permission target=\(target.id) current=\(system.currentSourceID ?? "unknown") " +
            "elapsed_ms=0 timeout_ms=0 permission=\(permission.rawValue) status=n/a"
        )
        guard permission.isGranted else {
            throw InputSourceHandoffError.postEventPermissionDenied
        }

        let preferredBridge = system.currentSourceID.flatMap(system.sourceState)
        guard let bridge = Self.resolveBridge(
            preferred: preferredBridge,
            candidates: system.asciiCapableSourceStates(),
            targetID: target.id
        ) else {
            throw InputSourceHandoffError.noBridge(target.id)
        }

        try throwIfSuperseded(isSuperseded)
        try await selectAndObserve(
            sourceID: target.id,
            phase: "seed-target",
            permission: permission
        )
        try throwIfSuperseded(isSuperseded)

        do {
            try await selectAndObserve(
                sourceID: bridge.id,
                phase: "select-bridge",
                permission: permission
            )
            try await postAndObserve(
                shortcut: shortcut,
                expectedSourceID: target.id,
                permission: permission
            )
            try await settle(sourceID: target.id, permission: permission)
        } catch {
            restoreTargetIfBridgeRemainsActive(target.id)
            throw error
        }

        if isSuperseded() {
            throw SupersededInputSourceRequest()
        }
    }

    func isInternallyPosting(_ signature: ShortcutSignature) -> Bool {
        postedShortcutSignature == signature
    }

    nonisolated static func resolveBridge(
        preferred: InputSourceState?,
        candidates: [InputSourceState],
        targetID: String
    ) -> InputSourceState? {
        if let preferred,
           preferred.id != targetID,
           preferred.isSafeBridge {
            return preferred
        }
        return candidates
            .filter { $0.id != targetID && $0.isSafeBridge }
            .sorted { $0.id < $1.id }
            .first
    }

    private func selectKeyboardLayout(_ target: InputSourceSelectionTarget) throws {
        let startedAt = Date()
        let status = system.select(sourceID: target.id)
        diagnostics(
            diagnosticLine(
                phase: "select-layout",
                expectedSourceID: target.id,
                startedAt: startedAt,
                notificationCount: 0,
                permission: nil,
                status: status
            )
        )
        guard status == noErr else {
            throw InputSourceHandoffError.selectionFailed(
                phase: "select-layout",
                sourceID: target.id,
                status: status
            )
        }
    }

    private func waitForShortcutRelease() async throws {
        let startedAt = Date()
        // Five seconds bounds a stuck modifier state while allowing an intentionally held shortcut.
        let timeout: TimeInterval = 5
        while !system.shortcutModifierFlags.intersection(Self.shortcutModifiers).isEmpty {
            guard Date().timeIntervalSince(startedAt) < timeout else {
                diagnostics(
                    "phase=release-shortcut current=\(system.currentSourceID ?? "unknown") " +
                    "elapsed_ms=\(milliseconds(since: startedAt)) timeout_ms=5000 " +
                    "permission=not-checked status=n/a outcome=timeout"
                )
                throw InputSourceHandoffError.shortcutReleaseTimedOut
            }
            // Ten milliseconds keeps release detection responsive without an Input Monitoring event tap.
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        diagnostics(
            "phase=release-shortcut current=\(system.currentSourceID ?? "unknown") " +
            "elapsed_ms=\(milliseconds(since: startedAt)) timeout_ms=5000 " +
            "permission=not-checked status=n/a outcome=complete"
        )
    }

    private func selectAndObserve(
        sourceID: String,
        phase: String,
        permission: PostEventPermissionState
    ) async throws {
        let initialSourceID = system.currentSourceID
        let startedAt = Date()
        let observation = InputSourceChangeObservation(center: notificationCenter)
        defer { observation.stop() }

        let status = system.select(sourceID: sourceID)
        guard status == noErr else {
            diagnostics(
                diagnosticLine(
                    phase: phase,
                    expectedSourceID: sourceID,
                    startedAt: startedAt,
                    notificationCount: observation.notificationCount,
                    permission: permission,
                    status: status
                )
            )
            throw InputSourceHandoffError.selectionFailed(
                phase: phase,
                sourceID: sourceID,
                status: status
            )
        }

        try await waitForSource(
            sourceID,
            phase: phase,
            initialSourceID: initialSourceID,
            observation: observation,
            startedAt: startedAt,
            permission: permission,
            status: status
        )
    }

    private func postAndObserve(
        shortcut: NativePreviousInputSourceShortcut,
        expectedSourceID: String,
        permission: PostEventPermissionState
    ) async throws {
        let phase = "native-previous"
        let initialSourceID = system.currentSourceID
        let startedAt = Date()
        let observation = InputSourceChangeObservation(center: notificationCenter)
        defer { observation.stop() }

        postedShortcutSignature = shortcut.signature
        defer { postedShortcutSignature = nil }
        do {
            try system.postPreviousInputSourceShortcut(shortcut)
        } catch {
            diagnostics(
                diagnosticLine(
                    phase: phase,
                    expectedSourceID: expectedSourceID,
                    startedAt: startedAt,
                    notificationCount: observation.notificationCount,
                    permission: permission,
                    status: nil,
                    outcome: "post-error"
                )
            )
            throw error
        }

        try await waitForSource(
            expectedSourceID,
            phase: phase,
            initialSourceID: initialSourceID,
            observation: observation,
            startedAt: startedAt,
            permission: permission,
            status: nil
        )
    }

    private func waitForSource(
        _ expectedSourceID: String,
        phase: String,
        initialSourceID: String?,
        observation: InputSourceChangeObservation,
        startedAt: Date,
        permission: PostEventPermissionState,
        status: OSStatus?
    ) async throws {
        await yieldMainRunLoop()
        while true {
            try Task.checkCancellation()
            let currentSourceID = system.currentSourceID
            let notificationObserved = observation.notificationCount > 0
            if currentSourceID == expectedSourceID,
               notificationObserved || initialSourceID == expectedSourceID {
                diagnostics(
                    diagnosticLine(
                        phase: phase,
                        expectedSourceID: expectedSourceID,
                        startedAt: startedAt,
                        notificationCount: observation.notificationCount,
                        permission: permission,
                        status: status
                    )
                )
                return
            }
            guard Date().timeIntervalSince(startedAt) < phaseTimeout else {
                diagnostics(
                    diagnosticLine(
                        phase: phase,
                        expectedSourceID: expectedSourceID,
                        startedAt: startedAt,
                        notificationCount: observation.notificationCount,
                        permission: permission,
                        status: status,
                        outcome: "timeout"
                    )
                )
                throw InputSourceHandoffError.transitionTimedOut(
                    phase: phase,
                    expectedID: expectedSourceID,
                    currentID: currentSourceID
                )
            }
            // Ten milliseconds tolerates notification/current-source skew without busy-waiting.
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func settle(
        sourceID: String,
        permission: PostEventPermissionState
    ) async throws {
        let startedAt = Date()
        // Kawa used 50 ms; one bounded interval lets the focused text client consume the native hop.
        try await Task.sleep(nanoseconds: 50_000_000)
        await yieldMainRunLoop()
        let currentSourceID = system.currentSourceID
        diagnostics(
            "phase=settle expected=\(sourceID) current=\(currentSourceID ?? "unknown") " +
            "elapsed_ms=\(milliseconds(since: startedAt)) timeout_ms=50 " +
            "permission=\(permission.rawValue) status=n/a " +
            "outcome=\(currentSourceID == sourceID ? "complete" : "changed")"
        )
        guard currentSourceID == sourceID else {
            throw InputSourceHandoffError.sourceChangedDuringSettle(
                expectedID: sourceID,
                currentID: currentSourceID
            )
        }
    }

    private func restoreTargetIfBridgeRemainsActive(_ targetID: String) {
        guard system.currentSourceID != targetID else { return }
        let status = system.select(sourceID: targetID)
        diagnostics(
            "phase=recover-target expected=\(targetID) current=\(system.currentSourceID ?? "unknown") " +
            "elapsed_ms=0 timeout_ms=0 permission=unknown status=\(status) outcome=recovery"
        )
    }

    private func throwIfSuperseded(
        _ isSuperseded: @MainActor () -> Bool
    ) throws {
        if isSuperseded() {
            throw SupersededInputSourceRequest()
        }
    }

    private func yieldMainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func diagnosticLine(
        phase: String,
        expectedSourceID: String,
        startedAt: Date,
        notificationCount: Int,
        permission: PostEventPermissionState?,
        status: OSStatus?,
        outcome: String = "complete"
    ) -> String {
        "phase=\(phase) expected=\(expectedSourceID) current=\(system.currentSourceID ?? "unknown") " +
            "elapsed_ms=\(milliseconds(since: startedAt)) timeout_ms=\(Int(phaseTimeout * 1_000)) " +
            "notifications=\(notificationCount) permission=\(permission?.rawValue ?? "not-required") " +
            "status=\(status.map(String.init) ?? "n/a") outcome=\(outcome)"
    }

    private func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }
}

@MainActor
final class InputSourceSelector {
    static let shared = InputSourceSelector(selection: NativeInputSourceHandoff())

    private let selection: InputSourceSelecting
    private let reportFailure: @MainActor (Error) -> Void
    private var pendingTarget: InputSourceSelectionTarget?
    private var latestRevision = 0
    private var worker: Task<Void, Never>?

    var isIdle: Bool {
        worker == nil
    }

    init(
        selection: InputSourceSelecting,
        reportFailure: @escaping @MainActor (Error) -> Void = InputSourceSelector.presentFailure
    ) {
        self.selection = selection
        self.reportFailure = reportFailure
    }

    func request(_ inputSource: InputSource) {
        request(InputSourceSelectionTarget(inputSource))
    }

    func request(_ target: InputSourceSelectionTarget) {
        latestRevision &+= 1
        pendingTarget = target
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drainPendingRequests()
        }
    }

    func shouldHandleShortcut(named name: KeyboardShortcuts.Name) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            return true
        }
        let signature = ShortcutSignature(
            keyCode: shortcut.carbonKeyCode,
            carbonModifiers: shortcut.carbonModifiers
        )
        return shouldHandleShortcut(signature)
    }

    func shouldHandleShortcut(_ signature: ShortcutSignature) -> Bool {
        !selection.isInternallyPosting(signature)
    }

    private func drainPendingRequests() async {
        while let target = pendingTarget {
            pendingTarget = nil
            let revision = latestRevision
            do {
                try await selection.select(target) { [weak self] in
                    self?.latestRevision != revision
                }
            } catch is SupersededInputSourceRequest {
                continue
            } catch is CancellationError {
                continue
            } catch {
                if latestRevision == revision {
                    reportFailure(error)
                }
            }
        }
        worker = nil
    }

    private static func presentFailure(_ error: Error) {
        NSLog("Input-source shortcut failed: %@", error.localizedDescription)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Input source could not be activated"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        // Accessory apps must activate explicitly or a setup failure can stay hidden.
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        alert.runModal()
    }
}
