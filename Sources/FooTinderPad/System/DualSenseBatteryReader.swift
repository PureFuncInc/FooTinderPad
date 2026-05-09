import Foundation
import IOKit
import IOKit.hid
import os

/// IOKit-based battery fallback for Sony DualSense over Bluetooth.
///
/// `GCController.battery` returns `.none` for some BT-only DualSense
/// configurations on macOS. This class opens the DualSense via `IOHIDManager`
/// alongside `gamecontrollerd` (verified non-conflicting via PoC), flips the
/// controller into extended report mode (`0x31`) by issuing a Get Feature
/// Report `0x05` (calibration — read-only, the mode flip is a side effect),
/// and parses the battery byte from each input report.
///
/// Lifecycle (attach/detach/IOHIDManager) is not unit-tested for the same
/// reason `BatteryMonitor`'s isn't — there is no mock for `IOHIDDevice` and
/// the cost/benefit of building one is not worth it. The pure `parse(report:)`
/// helper is the unit-test target.
///
/// Threading: `attach()` / `detach()` must be called on the main thread.
/// IOHIDManager is scheduled on the main run loop, so all callbacks fire on
/// the main thread — instance state mutations (`current`, `device`) need no
/// further locking.
final class DualSenseBatteryReader {

    private static let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "DualSenseBatteryReader")

    /// Sony Vendor ID.
    private static let sonyVendorID: Int = 0x054C
    /// PS5 DualSense Product ID.
    private static let dualSensePID: Int = 0x0CE6
    /// DualSense Bluetooth report 0x31 is 78 bytes; we allocate 128 (next
    /// power-of-two) to give IOKit headroom and align cleanly.
    private static let bufferLength = 128

    /// Parse the battery byte at offset 54 of a DualSense Bluetooth `0x31`
    /// input report. Returns `.none` for any malformed or undocumented input.
    ///
    /// Format (from open-source DualSense projects + verified by PoC):
    /// - low nibble (`bits 0..3`): battery level 0..10, mapped to 0..100% in
    ///   10% steps. Clamped to 10 if firmware reports out-of-range.
    /// - high nibble (`bits 4..7`): state — `0` discharging, `1` charging,
    ///   `2` full. Other values are undocumented (some references list `3` as
    ///   abnormal voltage / temperature error) and map to `.none`.
    static func parse(report bytes: [UInt8]) -> BatterySuffix {
        guard bytes.count > 54 else { return .none }
        let b = bytes[54]
        let level = min(Int(b & 0x0F), 10) * 10
        let state = (b & 0xF0) >> 4
        switch state {
        case 0:
            return .discharging(level: level)
        case 1:
            return level >= 100 ? .full : .charging(level: level)
        case 2:
            return .full
        default:
            return .none
        }
    }

    private(set) var current: BatterySuffix = .none
    var onChange: ((BatterySuffix) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    /// Opaque `self` pointer for C-callback `context` arguments. Computed each
    /// call (zero cost) so there's only one place to change if the bridging
    /// pattern is ever revisited.
    private var opaque: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    private let reportBuffer: UnsafeMutablePointer<UInt8> =
        UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)

    deinit {
        // detach() is the proper teardown path; this is a defensive safety
        // net that frees the buffer if the reader is released without one
        // (e.g. process teardown).
        reportBuffer.deallocate()
    }

    /// Open IOHIDManager, match Sony / DualSense, subscribe to input reports.
    /// Idempotent — calling twice is a no-op.
    func attach() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Self.sonyVendorID,
            kIOHIDProductIDKey: Self.dualSensePID,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, Self.matchedCallback, opaque)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, Self.removedCallback, opaque)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            Self.log.warning("IOHIDManagerOpen failed: 0x\(String(format: "%x", r), privacy: .public); battery fallback disabled")
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return
        }
        self.manager = mgr
    }

    /// Close IOHIDManager + IOHIDDevice, drop cached state. Idempotent.
    func detach() {
        guard let mgr = manager else { return }
        // Unschedule first so no pending input-report callback can fire after
        // the device is closed; then close the device, then the manager.
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        if let dev = device {
            IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        device = nil
        if current != .none {
            current = .none
            onChange?(.none)
        }
    }

    // MARK: - Internal callback handlers (called on main thread)

    fileprivate func handleMatched(_ matchedDevice: IOHIDDevice) {
        // Only track the first matched DualSense — single-controller assumption
        // that matches ControllerManager's active-controller stack.
        guard device == nil else { return }

        let r = IOHIDDeviceOpen(matchedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            Self.log.warning("IOHIDDeviceOpen failed: 0x\(String(format: "%x", r), privacy: .public)")
            return
        }
        device = matchedDevice

        IOHIDDeviceRegisterInputReportCallback(matchedDevice, reportBuffer, Self.bufferLength, Self.inputReportCallback, opaque)

        // Trigger 0x31 mode by reading feature report 0x05 (calibration).
        // The data we get back is discarded — only the mode flip matters.
        var calib = [UInt8](repeating: 0, count: 41)
        var len = CFIndex(calib.count)
        let r2 = calib.withUnsafeMutableBufferPointer { bptr -> IOReturn in
            return IOHIDDeviceGetReport(matchedDevice, kIOHIDReportTypeFeature, 0x05, bptr.baseAddress!, &len)
        }
        if r2 != kIOReturnSuccess {
            Self.log.warning("Get Feature Report 0x05 failed: 0x\(String(format: "%x", r2), privacy: .public); 0x31 mode may not be active")
        }
    }

    fileprivate func handleRemoved(_ removedDevice: IOHIDDevice) {
        if device === removedDevice {
            device = nil
            if current != .none {
                current = .none
                onChange?(.none)
            }
        }
    }

    fileprivate func handleInputReport(reportID: UInt32, bytes: [UInt8]) {
        guard reportID == 0x31 else { return }
        let new = Self.parse(report: bytes)
        if new != current {
            current = new
            onChange?(new)
        }
    }

    // MARK: - C-style callbacks (must match IOKit function-pointer signatures)

    private static let matchedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context = context else { return }
        let reader = Unmanaged<DualSenseBatteryReader>.fromOpaque(context).takeUnretainedValue()
        reader.handleMatched(device)
    }

    private static let removedCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context = context else { return }
        let reader = Unmanaged<DualSenseBatteryReader>.fromOpaque(context).takeUnretainedValue()
        reader.handleRemoved(device)
    }

    private static let inputReportCallback: IOHIDReportCallback = { context, _, _, _, reportID, report, length in
        guard let context = context else { return }
        let reader = Unmanaged<DualSenseBatteryReader>.fromOpaque(context).takeUnretainedValue()
        let bytes = Array(UnsafeBufferPointer(start: report, count: length))
        reader.handleInputReport(reportID: reportID, bytes: bytes)
    }
}
