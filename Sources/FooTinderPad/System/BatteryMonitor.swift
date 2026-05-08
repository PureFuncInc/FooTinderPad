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
/// Instance methods drive a 30 s timer and emit `onChange` only when the
/// rendered suffix actually moves; the static helper below is the pure
/// rendering rule.
final class BatteryMonitor {

    /// Polling cadence. Battery levels move slowly, and menu re-opens trigger
    /// an extra refresh on demand, so 30 s is plenty fresh for the menu bar.
    private static let refreshInterval: TimeInterval = 30

    private weak var controller: GCController?
    private var timer: Timer?
    private(set) var current: BatterySuffix = .none
    var onChange: ((BatterySuffix) -> Void)?

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

    /// Bind to a controller (or unbind by passing nil). Tears down the previous
    /// timer and starts a fresh one when the new target is non-nil. A read +
    /// possible `onChange` always follows so the UI converges immediately.
    func bind(controller: GCController?) {
        self.controller = controller
        timer?.invalidate()
        timer = nil
        if controller != nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
        refresh()
    }

    /// Re-read the battery property and fire onChange iff the rendered suffix changed.
    /// Cheap — safe to call from `menuWillOpen`.
    func refresh() {
        let new: BatterySuffix
        if let battery = controller?.battery {
            new = Self.suffix(level: battery.batteryLevel, state: battery.batteryState)
        } else {
            new = .none
        }
        if new != current {
            current = new
            onChange?(new)
        }
    }

    /// Tear down for app shutdown.
    func stop() {
        timer?.invalidate()
        timer = nil
        controller = nil
        onChange = nil
    }
}
