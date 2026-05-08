import Foundation
import GameController

enum BatterySuffix: Equatable {
    case none                         // unknown / no battery / no controller
    case discharging(level: Int)      // 0...100
    case charging(level: Int)         // 0...100, never 100 (use .full)
    case full                         // rendered as "⚡100%"

    /// Red text only applies to discharging. While charging — even at low level —
    /// the user is already acting; reddening the value would be noise.
    var isLow: Bool {
        if case .discharging(let n) = self { return n <= 20 }
        return false
    }
}

/// Owns the lifetime of battery polling for the active controller.
/// The static helper below is the pure rendering rule; instance methods
/// (added in the next task) drive a 30 s timer and emit `onChange`.
final class BatteryMonitor {

    static func suffix(level: Float, state: GCDeviceBattery.State) -> BatterySuffix {
        let n = Int((max(0, min(1, level)) * 100).rounded())
        switch state {
        case .unknown:     return .none
        case .discharging: return .discharging(level: n)
        case .charging:    return n >= 100 ? .full : .charging(level: n)
        case .full:        return .full
        @unknown default:  return .none
        }
    }
}
