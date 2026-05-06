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

enum LaunchAtLoginError: Error, LocalizedError {
    case noExecutablePath
    var errorDescription: String? {
        switch self {
        case .noExecutablePath: return "could not resolve app executable path"
        }
    }
}

final class LaunchAtLogin {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "LaunchAtLogin")
    private let plistURL: URL
    private(set) var state: LaunchAtLoginState

    /// Called on the main queue every time `state` transitions.
    var onStateChange: ((LaunchAtLoginState) -> Void)?

    static let defaultPlistURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.purefuncinc.FooTinderPad.plist")
    }()

    init(plistURL: URL = LaunchAtLogin.defaultPlistURL) {
        self.plistURL = plistURL
        self.state = Self.readState(plistURL: plistURL)
        log.info("initial launch-at-login state: \(String(describing: self.state), privacy: .public)")
    }

    /// Re-reads state. Plist-first (LaunchAgent path wins if present), else SMAppService.
    func refresh() {
        let next = Self.readState(plistURL: plistURL)
        guard next != state else { return }
        log.info("launch-at-login state changed: \(String(describing: next), privacy: .public)")
        state = next
        onStateChange?(next)
    }

    /// State-aware click dispatch with SMAppService → LaunchAgent fallback on enable.
    func handleClick() {
        switch Self.action(for: state) {
        case .enable:
            var smaSucceeded = false
            do {
                try SMAppService.mainApp.register()
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval:
                    smaSucceeded = true
                default:
                    smaSucceeded = false
                }
            } catch {
                log.info("SMAppService.register failed (\(error.localizedDescription, privacy: .public)); falling back to LaunchAgent plist")
                smaSucceeded = false
            }
            if !smaSucceeded {
                guard let exec = Bundle.main.executableURL?.path else {
                    log.error("no executable path; cannot write plist")
                    state = .failed(LaunchAtLoginError.noExecutablePath.localizedDescription)
                    onStateChange?(state)
                    return
                }
                do {
                    try Self.writePlist(at: plistURL, executablePath: exec)
                } catch {
                    log.error("plist write failed: \(error.localizedDescription, privacy: .public)")
                    state = .failed(error.localizedDescription)
                    onStateChange?(state)
                    return
                }
            }
            refresh()

        case .disable:
            do {
                try Self.removePlistIfPresent(at: plistURL)
            } catch {
                log.error("plist remove failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                onStateChange?(state)
                return
            }
            try? SMAppService.mainApp.unregister()  // best-effort
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

    /// Reads state with plist-first priority. Internal so tests can call directly.
    static func readState(plistURL: URL) -> LaunchAtLoginState {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            return .enabled
        }
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .notRegistered:     return .disabled
        case .notFound:          return .disabled  // self-signed: looks "off, can enable" — fallback handles enable
        case .requiresApproval:  return .requiresApproval
        @unknown default:        return .failed("unknown SMAppService status")
        }
    }

    /// Writes the LaunchAgent plist atomically, creating parent directories as needed.
    static func writePlist(at url: URL, executablePath: String) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content: [String: Any] = [
            "Label": "com.purefuncinc.FooTinderPad",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: content, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Removes the plist if present. No-op when absent (idempotent).
    static func removePlistIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
