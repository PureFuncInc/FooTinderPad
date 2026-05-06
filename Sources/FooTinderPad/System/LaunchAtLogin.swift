import Foundation

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
    static func action(for state: LaunchAtLoginState) -> LaunchAtLoginAction {
        switch state {
        case .disabled:                      return .enable
        case .enabled:                       return .disable
        case .requiresApproval, .failed:     return .openSystemSettings
        }
    }
}
