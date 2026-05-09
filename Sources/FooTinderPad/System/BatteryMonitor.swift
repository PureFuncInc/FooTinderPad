import Foundation
import GameController
import os

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
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "BatteryMonitor")

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
    private let xbox = XboxBatteryReader()

    /// `GCController.vendorName` for the DualSense on macOS is reliably
    /// "DualSense Wireless Controller". Substring match keeps us robust to
    /// future suffixes (e.g. "Edge") and any USB-vs-BT vendorName variant.
    private static func isDualSense(_ c: GCController) -> Bool {
        return c.vendorName?.lowercased().contains("dualsense") == true
    }

    private static func isXbox(_ c: GCController) -> Bool {
        return c.vendorName?.lowercased().contains("xbox") == true
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
        logBinding(for: controller)
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
            // Clear the stale closure first so a non-DualSense rebind
            // doesn't leave a closure pointing at this monitor sitting
            // on the (about-to-be-detached) reader.
            dualsense.onChange = nil
            dualsense.detach()
        }
        if let c = controller, Self.isXbox(c) {
            xbox.onChange = { [weak self] _ in self?.refresh() }
            xbox.attach()
        } else {
            xbox.onChange = nil
            xbox.detach()
        }
        refresh()
    }

    private func logBinding(for controller: GCController?) {
        guard let controller else {
            log.info("battery unbound: no active controller")
            return
        }
        let name = controller.vendorName ?? "?"
        guard let battery = controller.battery else {
            log.info("battery bind: controller=\(name, privacy: .public) gcBattery=nil")
            return
        }
        log.info("battery bind: controller=\(name, privacy: .public) gcState=\(Self.describe(battery.batteryState), privacy: .public) gcLevel=\(battery.batteryLevel, privacy: .public)")
    }

    private static func describe(_ state: GCDeviceBattery.State) -> String {
        switch state {
        case .unknown: return "unknown"
        case .discharging: return "discharging"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unrecognized"
        }
    }

    /// Re-read the battery property and fire onChange iff the rendered suffix changed.
    /// Cheap — safe to call from `menuWillOpen`.
    func refresh() {
        if let c = controller, Self.isXbox(c) {
            xbox.refresh()
        }
        let gcc: BatterySuffix
        if let battery = controller?.battery {
            gcc = Self.suffix(level: battery.batteryLevel, state: battery.batteryState)
        } else {
            gcc = .none
        }
        // Fallback merge: GCC wins when it has data; controller-specific
        // readers fill in only when GCC reports nothing.
        let fallback = dualsense.current != .none ? dualsense.current : xbox.current
        let new = (gcc == .none) ? fallback : gcc
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
        xbox.detach()
    }
}
