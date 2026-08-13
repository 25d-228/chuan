import AppKit
import Carbon
import CoreGraphics
import Foundation

struct SwitchableInputSource: Equatable {
    let id: String
    let isCJKV: Bool
    fileprivate let tisInputSource: TISInputSource?

    init(_ inputSource: InputSource) {
        id = inputSource.id
        isCJKV = inputSource.source.sourceLanguages.first.map(Self.isCJKVLanguage) ?? false
        tisInputSource = inputSource.source
    }

    init(id: String, isCJKV: Bool) {
        self.id = id
        self.isCJKV = isCJKV
        tisInputSource = nil
    }

    private static func isCJKVLanguage(_ language: String) -> Bool {
        language == "ko" || language == "ja" || language == "vi" || language.hasPrefix("zh")
    }

    static func == (lhs: SwitchableInputSource, rhs: SwitchableInputSource) -> Bool {
        lhs.id == rhs.id && lhs.isCJKV == rhs.isCJKV
    }
}

struct PreviousInputSourceShortcut: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum InputSourceSwitchError: LocalizedError, Equatable {
    case sourceUnavailable(String)
    case nonCJKVBridgeUnavailable
    case previousSourceShortcutUnavailable
    case postEventPermissionDenied
    case selectionFailed(phase: String, sourceID: String, status: OSStatus)
    case nativeEventCreationFailed

    var errorDescription: String? {
        switch self {
        case let .sourceUnavailable(sourceID):
            return "Input source \(sourceID) is unavailable. Refresh input sources and try again."
        case .nonCJKVBridgeUnavailable:
            return "Enable a non-CJKV input source before switching to a CJKV input method."
        case .previousSourceShortcutUnavailable:
            return "Enable Select the previous input source in System Settings > Keyboard > Keyboard Shortcuts > Input Sources."
        case .postEventPermissionDenied:
            return "Enable Chuan in System Settings > Privacy & Security > Accessibility, then quit and reopen Chuan."
        case let .selectionFailed(phase, sourceID, status):
            return "Could not select \(sourceID) during \(phase) (TIS status \(status))."
        case .nativeEventCreationFailed:
            return "Chuan could not post the macOS previous-input-source shortcut."
        }
    }
}

@MainActor
protocol InputSourceSwitchingSystem: AnyObject {
    func previousInputSourceShortcut() throws -> PreviousInputSourceShortcut
    func ensurePostEventAccess() -> Bool
    func select(_ inputSource: SwitchableInputSource) -> OSStatus
    func postPreviousInputSourceShortcut(_ shortcut: PreviousInputSourceShortcut) -> Bool
}

@MainActor
final class LiveInputSourceSwitchingSystem: InputSourceSwitchingSystem {
    private static let previousInputSourceShortcutID = "60"
    private static let keyCodeParameterIndex = 1
    private static let modifierParameterIndex = 2

    private var didRequestPostEventAccess = false

    func previousInputSourceShortcut() throws -> PreviousInputSourceShortcut {
        let domain = UserDefaults.standard.persistentDomain(
            forName: "com.apple.symbolichotkeys"
        ) ?? [:]
        guard let entries = domain["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = entries[Self.previousInputSourceShortcutID] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.indices.contains(Self.modifierParameterIndex),
              let keyCode = parameters[Self.keyCodeParameterIndex] as? NSNumber,
              let modifiers = parameters[Self.modifierParameterIndex] as? NSNumber,
              keyCode.intValue >= 0,
              keyCode.intValue <= Int(UInt16.max) else {
            throw InputSourceSwitchError.previousSourceShortcutUnavailable
        }
        return PreviousInputSourceShortcut(
            keyCode: CGKeyCode(keyCode.intValue),
            flags: CGEventFlags(rawValue: modifiers.uint64Value)
        )
    }

    func ensurePostEventAccess() -> Bool {
        if CGPreflightPostEventAccess() {
            return true
        }
        guard !didRequestPostEventAccess else { return false }
        didRequestPostEventAccess = true
        return CGRequestPostEventAccess()
    }

    func select(_ inputSource: SwitchableInputSource) -> OSStatus {
        guard let tisInputSource = inputSource.tisInputSource else {
            return OSStatus(paramErr)
        }
        return TISSelectInputSource(tisInputSource)
    }

    func postPreviousInputSourceShortcut(_ shortcut: PreviousInputSourceShortcut) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
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
            return false
        }

        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

@MainActor
final class InputSourceSwitcher {
    private struct CJKVSwitch {
        let target: SwitchableInputSource
        let bridge: SwitchableInputSource
        let shortcut: PreviousInputSourceShortcut
    }

    private enum PreparedSwitch {
        case direct(SwitchableInputSource)
        case cjkv(CJKVSwitch)
        case unavailable(InputSourceSwitchError)
    }

    static let shared = InputSourceSwitcher()

    private let system: InputSourceSwitchingSystem
    private let setupFailureReporter: ((InputSourceSwitchError) -> Void)?
    private var preparedSwitches: [String: PreparedSwitch] = [:]
    private var reportedSetupFailures = Set<String>()

    init(
        system: InputSourceSwitchingSystem? = nil,
        reportSetupFailure: ((InputSourceSwitchError) -> Void)? = nil
    ) {
        self.system = system ?? LiveInputSourceSwitchingSystem()
        setupFailureReporter = reportSetupFailure
    }

    func prepare(_ inputSources: [SwitchableInputSource]) {
        preparedSwitches = [:]
        let cjkvSources = inputSources.filter(\.isCJKV)

        for source in inputSources where !source.isCJKV {
            preparedSwitches[source.id] = .direct(source)
        }
        guard !cjkvSources.isEmpty else { return }

        let setup: Result<(
            bridge: SwitchableInputSource,
            shortcut: PreviousInputSourceShortcut
        ), InputSourceSwitchError>
        do {
            guard let bridge = inputSources.first(where: { !$0.isCJKV }) else {
                throw InputSourceSwitchError.nonCJKVBridgeUnavailable
            }
            let shortcut = try system.previousInputSourceShortcut()
            setup = .success((bridge, shortcut))
        } catch let error as InputSourceSwitchError {
            setup = .failure(error)
        } catch {
            setup = .failure(.previousSourceShortcutUnavailable)
        }

        for target in cjkvSources {
            switch setup {
            case let .success(setup):
                preparedSwitches[target.id] = .cjkv(CJKVSwitch(
                    target: target,
                    bridge: setup.bridge,
                    shortcut: setup.shortcut
                ))
            case let .failure(error):
                preparedSwitches[target.id] = .unavailable(error)
            }
        }
    }

    @discardableResult
    func switchTo(sourceID: String) -> InputSourceSwitchError? {
        guard let preparedSwitch = preparedSwitches[sourceID] else {
            let error = InputSourceSwitchError.sourceUnavailable(sourceID)
            reportSetupFailureOnce(error)
            return error
        }

        switch preparedSwitch {
        case let .direct(target):
            return select(target, phase: "target")
        case let .cjkv(inputMethodSwitch):
            guard system.ensurePostEventAccess() else {
                let error = InputSourceSwitchError.postEventPermissionDenied
                reportSetupFailureOnce(error)
                return error
            }
            if let error = select(inputMethodSwitch.target, phase: "target") {
                return error
            }
            if let error = select(inputMethodSwitch.bridge, phase: "bridge") {
                return error
            }
            guard system.postPreviousInputSourceShortcut(inputMethodSwitch.shortcut) else {
                return .nativeEventCreationFailed
            }
            return nil
        case let .unavailable(error):
            reportSetupFailureOnce(error)
            return error
        }
    }

    private func select(
        _ inputSource: SwitchableInputSource,
        phase: String
    ) -> InputSourceSwitchError? {
        let status = system.select(inputSource)
        guard status != noErr else { return nil }
        return .selectionFailed(
            phase: phase,
            sourceID: inputSource.id,
            status: status
        )
    }

    private func reportSetupFailureOnce(_ error: InputSourceSwitchError) {
        guard reportedSetupFailures.insert(error.localizedDescription).inserted else { return }
        if let setupFailureReporter {
            setupFailureReporter(error)
            return
        }

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
