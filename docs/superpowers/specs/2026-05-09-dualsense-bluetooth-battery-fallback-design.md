# DualSense Bluetooth Battery Fallback — Design

## Goal

Make the menu-bar battery indicator (added in PR #4) actually work for PS5 DualSense connected over Bluetooth. Today, `GCDeviceBattery` returns `nil` / `.unknown` for BT-only DualSense on macOS in some configurations, so the suffix never appears unless the user plugs in USB. This design adds a thin IOKit-based fallback that reads the battery byte directly from DualSense's HID input reports.

## Scope

- **In scope**: PS5 DualSense (`vid=0x054C`, `pid=0x0CE6`). New `DualSenseBatteryReader` class wraps an `IOHIDManager` matching that VID/PID, opens the device alongside `gamecontrollerd`, sends a Get Feature Report `0x05` to flip the controller into extended report mode (`0x31`), parses the battery byte from each report, and exposes a `BatterySuffix` plus an `onChange` callback. `BatteryMonitor.refresh()` consults the reader as a fallback when `GCController.battery` returns `.none`.
- **Out of scope**: PS4 DualShock4 (different battery offset), Xbox Wireless (entirely different GIP protocol), DualSense Edge (`pid=0x0DF2`, may need a separate map entry but defer until requested), real-time battery streaming faster than the current 30 s timer, low-battery push notifications, vibration / LED control via output reports, restoring DualSense to basic mode on app quit (no documented HID command exists; persistence in `0x31` is benign).

## Background — what the PoC established

A standalone Swift script using `IOHIDManager` was used to confirm three load-bearing assumptions before designing this feature:

1. **`IOHIDDeviceOpen` succeeds while `gamecontrollerd` is also using the device.** First PoC run received 1538 input reports of ID `0x01` (basic mode) over 25 s alongside the running app. No exclusivity error.
2. **A Get Feature Report `0x05` (which fetches calibration) flips the DualSense to extended report mode `0x31`** — and the controller *stays* in `0x31` mode across IOHIDManager close + reopen and even across app restarts (only un-pairing or power-cycling the controller resets it). Second PoC run after the trigger captured 1219 `0x31` reports.
3. **`gamecontrollerd` continues to deliver input events to the `GCController` API even after the controller has switched to `0x31` mode.** Verified by the user actively using FooTinderPad (mouse/keyboard from controller) while the DualSense was in `0x31` mode for an extended period — no input loss.

Battery byte location was identified by pattern-matching: across 3 consecutive `0x31` reports, `bytes[54]` was constant at `0x07`, while neighbouring bytes (`52`, `53`) varied. The user's PS5 system displayed 75 % at the time. With `low_nibble × 10 ≈ percent` (community-documented format), `0x07 → 70 %` falls in the 70–79 % bracket, matching observation. High nibble was `0` (discharging — controller was on battery).

## User-facing model

**No new UI**. The same `BatterySuffix` rendering used by PR #4 applies: `🎮 70%` for discharging, `🎮 ⚡70%` for charging, `🎮 ⚡100%` for full, no suffix when no data. The only difference: the BT-only DualSense case stops being silent.

Granularity is **10 % per step** (`low_nibble ∈ 0…10`) because that is what the controller reports natively over HID. The PS5 console can show finer values internally; we cannot.

## Architecture

A new wrapper class `DualSenseBatteryReader` lives in `Sources/FooTinderPad/System/`, alongside `BatteryMonitor`. It owns the IOHID lifecycle and the parsed `BatterySuffix`. `BatteryMonitor` composes it as a fallback source.

```swift
final class DualSenseBatteryReader {

    /// Pure parser. Public for testability; callers inside the file would
    /// normally use the instance's `current` instead.
    static func parse(report bytes: [UInt8]) -> BatterySuffix

    private(set) var current: BatterySuffix = .none
    var onChange: ((BatterySuffix) -> Void)?

    /// Open IOHIDManager, match Sony / DualSense, subscribe to input reports,
    /// trigger 0x31 mode. Idempotent — calling twice is a no-op.
    func attach()

    /// Close IOHIDManager + IOHIDDevice, drop cached state.
    func detach()
}
```

### Pure parser — `parse(report:)`

```swift
static func parse(report bytes: [UInt8]) -> BatterySuffix {
    // DualSense Bluetooth report 0x31 layout: 78 bytes including the 1-byte
    // report ID at bytes[0]. Battery byte is at offset 54.
    guard bytes.count > 54 else { return .none }
    let b = bytes[54]
    let level = min(Int(b & 0x0F), 10) * 10   // 0…10 → 0…100 (clamped)
    let state = (b & 0xF0) >> 4
    switch state {
    case 0:                       // discharging
        return .discharging(level: level)
    case 1:                       // charging (not full)
        return level >= 100 ? .full : .charging(level: level)
    case 2:                       // full
        return .full
    default:                      // 3+ = unknown / error / temperature warning
        return .none
    }
}
```

Notes on the format (sourced from open-source DualSense projects + the PoC observation):

- `level` low nibble is documented as `0…10` representing 0–100 % in 10 % steps. Out-of-range values (e.g. firmware quirk reporting `15`) are clamped to `10` so we never emit `>100 %`.
- `state` high nibble: `0` discharging, `1` charging, `2` full. Values `3–15` are implementation-defined / undocumented (some sources say `3` = abnormal voltage, `4` = temperature error, etc.). All non-{0,1,2} states map to `.none` — silent fallback rather than misrepresentation.
- The `level >= 100 ? .full : .charging` collapse mirrors `BatteryMonitor.suffix(level:state:)`'s rule, so the menu-bar render is consistent regardless of which path produced the value.

### `attach()` — IOHID lifecycle

```swift
func attach() {
    guard manager == nil else { return }   // idempotent

    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
        kIOHIDVendorIDKey: 0x054C,
        kIOHIDProductIDKey: 0x0CE6,
    ]
    IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchedCallback, selfPtr)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

    let r = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    if r != kIOReturnSuccess {
        log.warning("IOHIDManagerOpen failed: \(r); battery fallback disabled")
        return
    }
    self.manager = mgr
}
```

The `matchedCallback` (a C-style `IOHIDDeviceCallback` constant) bridges the Swift instance via the `selfPtr` `Unmanaged<DualSenseBatteryReader>` context, opens the matched device with `kIOHIDOptionsTypeNone` (non-seizing), registers the input-report callback against the device's `MaxInputReportSize` buffer, then issues `IOHIDDeviceGetReport(.feature, 0x05, ...)` once. The Get is read-only — its return value (calibration data) is discarded. The side effect — flipping into `0x31` mode — is the actual goal.

The input-report callback parses with `parse(report:)`, diff-checks against `current`, and fires `onChange` only on change.

### `detach()`

```swift
func detach() {
    guard let mgr = manager else { return }
    if let dev = device {
        IOHIDDeviceRegisterInputReportCallback(dev, reportBuffer, reportBufferLen, nil, nil)
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
    }
    IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    manager = nil
    device = nil
    if current != .none {
        current = .none
        onChange?(.none)
    }
}
```

### `BatteryMonitor` integration

Add a property + connect lifecycle to existing `bind`/`stop`. Modify `refresh()` to consult the reader when GCC has nothing.

```swift
// new
private let dualsense = DualSenseBatteryReader()

private static func isDualSense(_ c: GCController) -> Bool {
    // GCController.vendorName for the DualSense on macOS is reliably
    // "DualSense Wireless Controller". Substring match keeps us robust to
    // future suffixes (e.g. "Edge") and a USB-vs-BT vendorName variant.
    return c.vendorName?.lowercased().contains("dualsense") == true
}

// in bind(controller:) — append after the existing timer setup
if let c = controller, Self.isDualSense(c) {
    dualsense.onChange = { [weak self] _ in self?.refresh() }
    dualsense.attach()
} else {
    dualsense.detach()
}

// in refresh() — extend the existing logic
func refresh() {
    let gcc: BatterySuffix
    if let battery = controller?.battery {
        gcc = Self.suffix(level: battery.batteryLevel, state: battery.batteryState)
    } else {
        gcc = .none
    }
    let new = (gcc == .none) ? dualsense.current : gcc   // ← fallback merge
    if new != current {
        current = new
        onChange?(new)
    }
}

// in stop() — append
dualsense.detach()
```

`dualsense.onChange` calls `BatteryMonitor.refresh()` so any change in the reader's value re-evaluates the merge. This is push-driven (DS sends ~60 Hz) but the diff in `BatteryMonitor.refresh()` makes redundant fires cheap; the menu-bar `attributedTitle` is only rewritten on real value changes.

**Why gate the attach on `isDualSense`**: `IOHIDManager`'s VID/PID match would happily open a connected-but-not-active DualSense even if the user is currently using a different controller (e.g. an Xbox pad). The `refresh()` merge would then surface DualSense's battery as the fallback for the Xbox controller's icon — showing wrong data. Gating attach on the *active* controller's vendor name closes that path: reader only runs when its data is actually wanted.

### Why a separate class

- `BatteryMonitor` already coordinates a polling timer, GCC reads, accessibility-aware rebinding, and now would gain IOHIDManager + HID parsing if folded together. Keeping the IOKit specifics in their own file keeps each unit at one job.
- The pure parser is the only logic-dense piece worth unit-testing; isolating it on `DualSenseBatteryReader` keeps the test target focused.
- Future expansion (DualShock4, DualSense Edge) plugs into the same composition — if/when that's needed, it'd be a sibling class, not edits to `BatteryMonitor`.

## New / modified files

| File | Change |
|---|---|
| `Sources/FooTinderPad/System/DualSenseBatteryReader.swift` | **New.** Class above + `static parse(report:)` + IOHID lifecycle. Imports `IOKit`, `IOKit.hid`. |
| `Sources/FooTinderPad/System/BatteryMonitor.swift` | **Modify.** Add `private let dualsense = DualSenseBatteryReader()`. Modify `bind(controller:)` to attach/detach. Modify `refresh()` for the fallback merge. Modify `stop()` to detach. |
| `Tests/FooTinderPadTests/DualSenseBatteryReaderTests.swift` | **New.** Pure-parser tests covering each state nibble + clamping + short-report guard. |
| `Sources/FooTinderPad/AppDelegate.swift` | **Unchanged.** All wiring goes through `BatteryMonitor`. |
| `README.md` | **Unchanged.** The user-visible behavior matches what the existing paragraph promises — BT controllers that report battery now do so. |

`Info.plist` / `Makefile` / `Package.swift` — unchanged. `IOKit` is part of macOS and SwiftPM links it implicitly via `import IOKit.hid`.

## Edge cases

1. **DualSense already in `0x31` mode at attach** — `IOHIDDeviceGetReport(.feature, 0x05)` still succeeds (read-only call); idempotent. PoC verified across three runs.
2. **Get Feature Report `0x05` fails (returns non-success `IOReturn`)** — log a warning. `current` stays `.none`. If the controller was already in `0x31` mode (common), input reports flow anyway and the parser still works. If it was in `0x01` mode and the trigger failed, we gracefully return no battery info.
3. **`IOHIDDeviceOpen` fails** (e.g. an unusual seize from another tool) — log warning; reader stays inert; `current` stays `.none`; `BatteryMonitor` falls through to GCC's `.none` and shows just the icon. Existing behavior preserved.
4. **Multiple DualSense controllers connected** — `IOHIDManager` matching dictionary will match all of them; the matched-callback fires per device. We attach to the *first* matched device only and ignore subsequent matches (mirrors `ControllerManager`'s active-controller assumption — only one is in use at a time). Edge case is unlikely; document and move on.

4a. **DualSense connected but not active** (user is driving with another controller, e.g. Xbox) — the `isDualSense(active)` gate in `BatteryMonitor.bind` skips `attach()`, so the reader stays inert. The Xbox pad's `🎮` icon shows whatever GCC says (likely `.none` if Xbox doesn't report battery, matching its current behavior). DualSense battery is never confused for Xbox battery.
5. **Controller disconnects mid-stream** — IOKit invalidates the device handle; the next callback won't fire. `device = nil` on the next `attach()` cycle clears state. To keep `current` accurate, the device-removal callback (`IOHIDManagerRegisterDeviceRemovalCallback`) sets `current = .none` and fires `onChange`.
6. **Report byte count < 55** (malformed / firmware quirk) — `parse(report:)` returns `.none`. Current value is overwritten with `.none` only if it was already non-`.none`; one bad report does not flicker the suffix off then on (because the next valid report will refire `onChange` with the correct value).
7. **Charging at exactly 100 %** — `state == 1` with `level == 100` collapses to `.full` (mirrors `BatteryMonitor.suffix(level:state:)` semantics). `state == 2` does likewise.
8. **`level` low nibble = `0xF`** (firmware bug — out of documented range) — clamped to `10`, treated as 100 %. Defensive; unlikely to happen.
9. **State nibble outside {0,1,2}** — returned as `.none`, treated as "no info". Possible undocumented values (some references list `3` = "voltage error") are not surfaced because we cannot meaningfully render an error state on the menu bar.
10. **Persistent `0x31` mode side effect** — once flipped, the controller stays there until power-cycle / unpair. macOS 13+ `gamecontrollerd` parses `0x31` (verified via PoC + ongoing FooTinderPad usage). No restoration on app quit because no documented HID command exists to do so. If a future macOS version regresses on `0x31` parsing, BT input would break for users who once ran our app — extremely unlikely but worth recording.
11. **App-target macOS lower than 13** — `Package.swift` already declares macOS 13+. `IOHIDManager` and `GCController.battery` both predate this, so no platform gate needed.

## Testing

`Tests/FooTinderPadTests/DualSenseBatteryReaderTests.swift` covers `parse(report:)`. Lifecycle (`attach`/`detach`/IOHIDManager) is not unit-tested for the same reason `BatteryMonitor`'s lifecycle isn't: no realistic mock for `IOHIDDevice` and Apple framework calls. Coverage stance is the same pragmatic one used elsewhere in the project (see `LaunchAtLoginTests`, `AccessibilityGate`).

Each test passes a 78-byte buffer with known content; `bytes[54]` set to the test's input. Helper:

```swift
private func report(byte54: UInt8) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 78)
    buf[54] = byte54
    buf[0] = 0x31  // realistic header — parser shouldn't care
    return buf
}
```

Cases:

- `testParseDischargingMidLevel` — `byte54 = 0x07` → `.discharging(level: 70)`, `isLow == false`
- `testParseDischargingLow` — `byte54 = 0x02` → `.discharging(level: 20)`, `isLow == true`
- `testParseDischargingZero` — `byte54 = 0x00` → `.discharging(level: 0)`, `isLow == true`
- `testParseChargingMid` — `byte54 = 0x15` (high=1 charging, low=5) → `.charging(level: 50)`, `isLow == false`
- `testParseChargingLowNibbleStaysCharging` — `byte54 = 0x12` (high=1, low=2) → `.charging(level: 20)`, `isLow == false` (charging suppresses red)
- `testParseChargingFullCollapsesToFull` — `byte54 = 0x1A` (high=1, low=10) → `.full`
- `testParseFullState` — `byte54 = 0x2A` (high=2 full, low=10) → `.full`
- `testParseFullStateLowNibbleIgnored` — `byte54 = 0x20` (high=2 full, low=0) → `.full` (state wins; level zeroed bytes still mean "full" by spec)
- `testParseUnknownStateNibble` — `byte54 = 0x37` (high=3, undocumented) → `.none`
- `testParseLevelOverflowClamped` — `byte54 = 0x0F` (low=15, > 10) → `.discharging(level: 100)` (clamped)
- `testParseShortReportReturnsNone` — buffer length 30 → `.none`
- `testParseEmptyReportReturnsNone` — buffer length 0 → `.none`

### Manual smoke test (acceptance checklist)

1. `make clean && make install`. With no DualSense paired: menu bar `🎮` only (no regression vs PR #4).
2. **Bluetooth-only DualSense pair** (no USB cable). Within ~2 s of pairing or app launch, expect `🎮 70%` (or whatever the controller's current bracket is) — this is the new behavior this PR delivers.
3. While running: confirm cursor / button events still flow (gamecontrollerd coexistence — tested in PoC, smoke-test confirms it post-merge).
4. Plug in USB while app runs. Expect `🎮 ⚡70%` (charging icon) — GCC path takes over with charging state, matching PR #4 behavior. Unplug → returns to discharging via either path.
5. (Optional) Repeat with a controller that does NOT match the matching dictionary (e.g. an Xbox controller, if available). Confirm: bar still shows just `🎮` if GCC also lacks data, no errors logged.
6. Revoke Accessibility while connected → red unauthorized icon, no suffix (PR #4's race fix still holds; reader is detached via `BatteryMonitor.bind(nil)` triggered by `rebindBattery()`).
7. `swift test` → all existing 104 tests + 12 new `DualSenseBatteryReader` tests pass.

## Out of scope (future)

- DualSense Edge (`pid=0x0DF2`) — likely the same offset; defer until the user has one to verify.
- DualShock4 — different report layout, separate parser, defer until requested.
- Xbox Wireless on macOS — uses GIP not HID battery; separate vendor-specific message exchange; effort/complexity is out of proportion to value for this app's scope.
- Surfacing the "currently using IOKit fallback" state in the UI (debug overlay, log message) — log line on `attach()` is the only signal; if users ever want to know, README can grow a sentence.
- Restoring `0x01` mode on quit — no documented mechanism; gamecontrollerd's continued support of `0x31` makes the persistence benign.
