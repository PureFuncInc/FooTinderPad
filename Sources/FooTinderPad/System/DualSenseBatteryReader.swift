import Foundation
import IOKit
import IOKit.hid

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
final class DualSenseBatteryReader {

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
}
