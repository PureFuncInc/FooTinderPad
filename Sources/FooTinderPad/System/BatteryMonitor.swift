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
///
/// Naming note: this class uses `current` / `onChange` rather than the
/// `state` / `onStateChange` pair that `AccessibilityGate` and
/// `LaunchAtLogin` use. `BatterySuffix` is a presentation value (the
/// concrete string to render), not a domain state, so `state` would
/// mislead. The deviation is intentional.
final class BatteryMonitor {

    /// Polling cadence. Battery levels move slowly, and menu re-opens trigger
    /// an extra refresh on demand, so 30 s is plenty fresh for the menu bar.
    private static let refreshInterval: TimeInterval = 30

    private weak var controller: GCController?
    private var timer: Timer?
    private(set) var current: BatterySuffix = .none
    var onChange: ((BatterySuffix) -> Void)?

    /// IOKit fallback for BT-only DualSense, where `GCController.battery`
    /// returns `.none`. See spec 2026-05-09-dualsense-bluetooth-battery-fallback.
    private let dualsense = DualSenseBatteryReader()

    /// `GCController.vendorName` for the DualSense on macOS is reliably
    /// "DualSense Wireless Controller". Substring match keeps us robust to
    /// future suffixes (e.g. "Edge") and any USB-vs-BT vendorName variant.
    private static func isDualSense(_ c: GCController) -> Bool {
        return c.vendorName?.lowercased().contains("dualsense") == true
    }

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
    ///
    /// Must be called from the main thread — `Timer.scheduledTimer` uses the
    /// current run loop, and the only caller (`AppDelegate`) is main-thread.
    func bind(controller: GCController?) {
        self.controller = controller
        timer?.invalidate()
        timer = nil
        if controller != nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                self?.refresh()
            }
        }
        // Engage the IOKit fallback only when the active controller is a
        // DualSense — otherwise its battery would leak into the icon of
        // whichever controller is actually being driven (e.g. an Xbox pad
        // that's also connected). Reader is idempotent: re-attaching the
        // same device is a no-op.
        if let c = controller, Self.isDualSense(c) {
            dualsense.onChange = { [weak self] _ in self?.refresh() }
            dualsense.attach()
        } else {
            dualsense.detach()
        }
        refresh()
    }

    /// Re-read the battery property and fire onChange iff the rendered suffix changed.
    /// Cheap — safe to call from `menuWillOpen`.
    func refresh() {
        let gcc: BatterySuffix
        if let battery = controller?.battery {
            gcc = Self.suffix(level: battery.batteryLevel, state: battery.batteryState)
        } else {
            gcc = .none
        }
        // Fallback merge: GCC wins when it has data; DualSense IOKit reader
        // fills in only when GCC reports nothing.
        let new = (gcc == .none) ? dualsense.current : gcc
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
        dualsense.detach()
    }
}
