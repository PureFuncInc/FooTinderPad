import AppKit
import ServiceManagement
import os

enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case failed(String)
}

enum LaunchAtLoginAction: Equatable {
    case enable
    case disable
    case openSystemSettings
}

final class LaunchAtLogin {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "LaunchAtLogin")
    private(set) var state: LaunchAtLoginState

    /// Called on the main queue every time `state` transitions.
    var onStateChange: ((LaunchAtLoginState) -> Void)?

    init() {
        self.state = Self.readState()
        log.info("initial launch-at-login state: \(String(describing: self.state), privacy: .public)")
    }

    /// Re-reads `SMAppService.mainApp.status`. Called from `NSMenuDelegate.menuWillOpen`
    /// so external changes (e.g. user toggling in System Settings) sync on next menu open.
    func refresh() {
        let next = Self.readState()
        guard next != state else { return }
        log.info("launch-at-login state changed: \(String(describing: next), privacy: .public)")
        state = next
        onStateChange?(next)
    }

    /// State-aware click dispatch — see `LaunchAtLogin.action(for:)` for the routing rules.
    /// `.requiresApproval` / `.failed` route to System Settings because re-`register()`-ing
    /// before the user approves is a no-op and would leave them stuck.
    func handleClick() {
        switch Self.action(for: state) {
        case .enable:
            do {
                try SMAppService.mainApp.register()
            } catch {
                log.error("register failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                onStateChange?(state)
                return
            }
            refresh()

        case .disable:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                onStateChange?(state)
                return
            }
            refresh()

        case .openSystemSettings:
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    static func action(for state: LaunchAtLoginState) -> LaunchAtLoginAction {
        switch state {
        case .disabled:                      return .enable
        case .enabled:                       return .disable
        case .requiresApproval, .failed:     return .openSystemSettings
        }
    }

    private static func readState() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .notRegistered:     return .disabled
        case .requiresApproval:  return .requiresApproval
        case .notFound:          return .failed("login item not found")
        @unknown default:        return .failed("unknown SMAppService status")
        }
    }
}
