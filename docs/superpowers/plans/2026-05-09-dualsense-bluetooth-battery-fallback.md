# DualSense Bluetooth Battery Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `BatteryMonitor` show DualSense battery over Bluetooth-only by adding an IOKit-based fallback that reads the controller's HID input reports directly when `GCController.battery` returns `.none`.

**Architecture:** New `DualSenseBatteryReader` class in `Sources/FooTinderPad/System/` owns an `IOHIDManager`, matches Sony VID/PID, opens the DualSense alongside `gamecontrollerd`, sends `Get Feature Report 0x05` to flip the controller into extended report mode (`0x31`), parses the battery byte at offset 54, and exposes `current: BatterySuffix` + `onChange`. `BatteryMonitor.refresh()` consumes it as a fallback when GCC has no data; `BatteryMonitor.bind(controller:)` only attaches the reader when the active controller is a DualSense (matched via `vendorName`).

**Tech Stack:** Swift 5.9+, SwiftPM, IOKit (`IOKit.hid` — `IOHIDManager`, `IOHIDDevice`, `IOHIDDeviceGetReport`, `IOHIDDeviceRegisterInputReportCallback`), GameController (existing), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-09-dualsense-bluetooth-battery-fallback-design.md`

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/FooTinderPad/System/DualSenseBatteryReader.swift` | **new** | Pure `parse(report:)` static helper + class wrapping `IOHIDManager` lifecycle (attach/detach, matched/removal/input-report callbacks, Get Feature Report 0x05 trigger). |
| `Sources/FooTinderPad/System/BatteryMonitor.swift` | modify | Add `private let dualsense = DualSenseBatteryReader()`, `static func isDualSense(_:)` gate, attach/detach inside `bind(controller:)`, fallback-merge inside `refresh()`, detach inside `stop()`. |
| `Tests/FooTinderPadTests/DualSenseBatteryReaderTests.swift` | **new** | XCTest cases for the pure `parse(report:)` helper — every state nibble, level clamping, short-report guard. |

The pure parser is the only logic-dense piece worth unit-testing. Lifecycle (`attach`/`detach`/IOHIDManager) follows the project's pragmatic "no mock for system framework wrappers" stance (matches `AccessibilityGate`, `LaunchAtLogin`, `BatteryMonitor`'s existing untested orchestration).

---

## Task 1: DualSenseBatteryReader pure parser (TDD)

The static `parse(report:)` helper is the only logic-dense piece. TDD-first so byte parsing, level clamping, state nibble interpretation, and the short-report guard are all locked down before lifecycle code is written around it.

**Files:**
- Create: `Tests/FooTinderPadTests/DualSenseBatteryReaderTests.swift`
- Create: `Sources/FooTinderPad/System/DualSenseBatteryReader.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FooTinderPadTests/DualSenseBatteryReaderTests.swift`:

```swift
import XCTest
@testable import FooTinderPad

final class DualSenseBatteryReaderTests: XCTestCase {

    /// Build a 78-byte buffer with bytes[0]=0x31 (realistic header — parser
    /// shouldn't depend on it) and bytes[54] set to the test's input.
    private func report(byte54: UInt8) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 78)
        buf[0] = 0x31
        buf[54] = byte54
        return buf
    }

    // MARK: - Discharging (state nibble == 0)

    func testParseDischargingMidLevel() {
        // 0x07 → high=0 (discharging), low=7 → 70%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x07))
        XCTAssertEqual(s, .discharging(level: 70))
        XCTAssertFalse(s.isLow)
    }

    func testParseDischargingLow() {
        // 0x02 → discharging, 20%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x02))
        XCTAssertEqual(s, .discharging(level: 20))
        XCTAssertTrue(s.isLow, "20% is at the inclusive low threshold")
    }

    func testParseDischargingZero() {
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x00))
        XCTAssertEqual(s, .discharging(level: 0))
        XCTAssertTrue(s.isLow)
    }

    // MARK: - Charging (state nibble == 1)

    func testParseChargingMid() {
        // 0x15 → high=1 (charging), low=5 → 50%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x15))
        XCTAssertEqual(s, .charging(level: 50))
        XCTAssertFalse(s.isLow, "charging suppresses isLow")
    }

    func testParseChargingLowNibbleStaysCharging() {
        // 0x12 → charging at 20% — isLow must NOT trigger
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x12))
        XCTAssertEqual(s, .charging(level: 20))
        XCTAssertFalse(s.isLow)
    }

    func testParseChargingFullCollapsesToFull() {
        // 0x1A → high=1, low=10 → would be charging at 100%, but collapses to .full
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x1A))
        XCTAssertEqual(s, .full)
    }

    // MARK: - Full (state nibble == 2)

    func testParseFullState() {
        // 0x2A → high=2 (full), low=10
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x2A))
        XCTAssertEqual(s, .full)
    }

    func testParseFullStateLowNibbleIgnored() {
        // 0x20 → high=2 (full), low=0 — state wins regardless of level
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x20))
        XCTAssertEqual(s, .full)
    }

    // MARK: - Unknown / clamping / malformed

    func testParseUnknownStateNibble() {
        // 0x37 → high=3, undocumented — returns .none rather than misrender
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x37))
        XCTAssertEqual(s, .none)
    }

    func testParseLevelOverflowClamped() {
        // 0x0F → high=0 (discharging), low=15 (out of documented 0..10 range) — clamped to 10 → 100%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x0F))
        XCTAssertEqual(s, .discharging(level: 100))
    }

    func testParseShortReportReturnsNone() {
        // Buffer too short to reach byte 54
        let buf = [UInt8](repeating: 0, count: 30)
        XCTAssertEqual(DualSenseBatteryReader.parse(report: buf), .none)
    }

    func testParseEmptyReportReturnsNone() {
        XCTAssertEqual(DualSenseBatteryReader.parse(report: []), .none)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DualSenseBatteryReaderTests`
Expected: build error (`cannot find 'DualSenseBatteryReader' in scope`).

- [ ] **Step 3: Implement DualSenseBatteryReader skeleton + parse helper**

Create `Sources/FooTinderPad/System/DualSenseBatteryReader.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DualSenseBatteryReaderTests`
Expected: 12 tests pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/System/DualSenseBatteryReader.swift Tests/FooTinderPadTests/DualSenseBatteryReaderTests.swift
git commit -m "feat(battery): add DualSenseBatteryReader.parse pure helper

Static parser turns the battery byte at offset 54 of a DualSense BT
input report (0x31) into BatterySuffix. Low nibble maps 0..10 → 0..100%
(clamped); high nibble maps 0/1/2 → discharging/charging/full, others
→ .none for safe fallback. 12 unit tests cover each state nibble +
level clamping + short-report guard. Class body kept skeletal —
lifecycle code lands in the next task."
```

---

## Task 2: DualSenseBatteryReader IOHID lifecycle

Build the IOHIDManager wiring around the parser. No new tests — Apple HID framework calls are not user-mockable, and the project's pragmatic stance is "no protocol shim just to test a system wrapper". Verification is `swift build` clean + the 12 existing tests still passing + manual smoke later.

The trickiest piece is bridging the C-style `IOHIDDeviceCallback` / `IOHIDReportCallback` function pointers to instance methods. Standard Swift idiom: pass `Unmanaged.passUnretained(self).toOpaque()` as the `context` parameter, then in the C callback recover the instance with `Unmanaged<T>.fromOpaque(context).takeUnretainedValue()`. The class must outlive every callback registration — guaranteed here because the reader is owned by `BatteryMonitor` for the app's lifetime.

**Files:**
- Modify: `Sources/FooTinderPad/System/DualSenseBatteryReader.swift`

- [ ] **Step 1: Replace the file with the full implementation**

Replace the entire contents of `Sources/FooTinderPad/System/DualSenseBatteryReader.swift` with:

```swift
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
    private static let SONY_VID: Int = 0x054C
    /// PS5 DualSense Product ID.
    private static let DUALSENSE_PID: Int = 0x0CE6
    /// DualSense Bluetooth report 0x31 is 78 bytes; over-allocate for safety.
    private static let bufferLength = 128

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
    private let reportBuffer: UnsafeMutablePointer<UInt8> =
        UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)

    deinit {
        // detach() is the proper teardown path; deinit just frees the buffer
        // in case we're torn down without an explicit detach (e.g. test exit).
        reportBuffer.deallocate()
    }

    /// Open IOHIDManager, match Sony / DualSense, subscribe to input reports.
    /// Idempotent — calling twice is a no-op.
    func attach() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Self.SONY_VID,
            kIOHIDProductIDKey: Self.DUALSENSE_PID,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, Self.matchedCallback, selfPtr)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, Self.removedCallback, selfPtr)
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
        if let dev = device {
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

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(matchedDevice, reportBuffer, Self.bufferLength, Self.inputReportCallback, selfPtr)

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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: clean build, no warnings.

If you hit a compilation error on `IOHIDDeviceCallback` or `IOHIDReportCallback` signature mismatch (Apple has shifted these between SDK versions), check the type with `:print IOHIDDeviceCallback` in `swift repl` or read the IOKit headers. The signatures used here are the macOS 13+ ones.

- [ ] **Step 3: Run all tests to confirm nothing regressed**

Run: `swift test`
Expected: all existing tests + the 12 `DualSenseBatteryReaderTests` pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/FooTinderPad/System/DualSenseBatteryReader.swift
git commit -m "feat(battery): add DualSenseBatteryReader IOHID lifecycle

attach() opens IOHIDManager matching Sony VID 0x054C / DualSense PID
0x0CE6, schedules on the main run loop, registers matched + removal +
input-report callbacks. On match, opens the device, subscribes to
reports, and issues Get Feature Report 0x05 (read-only calibration
fetch — its side effect is flipping the controller into extended
report mode 0x31, where battery info is exposed).

input-report callback filters by reportID == 0x31 and feeds the bytes
through parse(report:); diff-on-set so onChange only fires when the
rendered suffix actually moves. C callbacks bridge to instance state
via the standard Unmanaged<T> + opaque-pointer pattern. Threading
assumption is main-thread (matches BatteryMonitor)."
```

---

## Task 3: Wire DualSenseBatteryReader into BatteryMonitor

Compose the reader as a fallback source. `BatteryMonitor.bind(controller:)` only attaches when the active controller is a DualSense (substring match on `vendorName`) — this prevents leaking DualSense battery into a different controller's icon when both are connected. `refresh()` consults the reader only when GCC has nothing.

**Files:**
- Modify: `Sources/FooTinderPad/System/BatteryMonitor.swift`

- [ ] **Step 1: Add `dualsense` property + `isDualSense` helper**

Open `Sources/FooTinderPad/System/BatteryMonitor.swift`. Find the existing property block:

```swift
    private weak var controller: GCController?
    private var timer: Timer?
    private(set) var current: BatterySuffix = .none
    var onChange: ((BatterySuffix) -> Void)?
```

Replace with:

```swift
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
```

- [ ] **Step 2: Modify `bind(controller:)` to attach/detach the reader on the active-DualSense gate**

Find the existing `bind(controller:)`:

```swift
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
```

Replace with:

```swift
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
```

- [ ] **Step 3: Modify `refresh()` for the fallback merge**

Find the existing `refresh()`:

```swift
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
```

Replace with:

```swift
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
```

- [ ] **Step 4: Modify `stop()` to detach the reader**

Find the existing `stop()`:

```swift
    func stop() {
        timer?.invalidate()
        timer = nil
        controller = nil
        onChange = nil
    }
```

Replace with:

```swift
    func stop() {
        timer?.invalidate()
        timer = nil
        controller = nil
        onChange = nil
        dualsense.detach()
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build`
Expected: clean build, no warnings.

- [ ] **Step 6: Run all tests**

Run: `swift test`
Expected: all tests pass (12 `DualSenseBatteryReaderTests` + the 12 `BatteryMonitorTests` + the rest of the suite).

- [ ] **Step 7: Commit**

```bash
git add Sources/FooTinderPad/System/BatteryMonitor.swift
git commit -m "feat(battery): wire DualSenseBatteryReader as fallback source

BatteryMonitor now composes a DualSenseBatteryReader and consults it
in refresh() when GCC reports .none. bind(controller:) gates attach
on isDualSense(c) so the reader only engages when the active
controller is a DualSense — prevents the reader's battery from
leaking into a different controller's icon when both are connected.
stop() detaches the reader for clean shutdown.

The reader's onChange routes back through BatteryMonitor.refresh(),
keeping the merge logic in one place. Diff-on-set in refresh() means
the ~60 Hz IOKit report stream only redraws the menu bar when the
rendered suffix actually moves."
```

---

## Task 4: Manual smoke test (user gate)

Visual confirmation against the spec's smoke checklist. No code changes. Steps 2 and 3 require physical DualSense hardware in BT-only mode — must be done by the human.

**Files:** none.

- [ ] **Step 1: Install the build**

Run: `make clean && make install`
Expected: `/Applications/FooTinderPad.app` is replaced with the freshly-built bundle and starts up. Menu-bar 🎮 idle icon appears (when no controller connected).

- [ ] **Step 2: Walk the smoke checklist**

Reference: `docs/superpowers/specs/2026-05-09-dualsense-bluetooth-battery-fallback-design.md` § Manual smoke test.

1. **No DualSense paired** → `🎮` only (no regression vs PR #4).
2. **Pair DualSense via Bluetooth (no USB cable)** → within ~2 s of pairing or app launch, expect `🎮 70%` (or whatever bracket the controller is in). This is the primary new behavior this PR delivers — without this test no one knows if the IOKit fallback works on the user's actual hardware.
3. **Use FooTinderPad while DualSense is BT-only** → cursor / button events flow normally. Confirms `gamecontrollerd` coexistence (proven in PoC, smoke-confirmed post-merge).
4. **Plug in USB while running** → `🎮 ⚡70%` (charging icon). GCC path takes over with charging state. Unplug → returns to discharging via IOKit fallback within 30 s or on next menu open.
5. **Connect a non-DualSense controller** (e.g. Xbox over BT) if available → `🎮` only, no incorrect battery suffix from a stand-by DualSense. (Skip if no second controller available; document in the report.)
6. **Revoke macOS Accessibility permission while connected** → red unauthorized icon, no suffix. Re-grant → suffix returns. (PR #4's race fix interacts with reader detach via `rebindBattery()` → `bind(nil)` → `dualsense.detach()`.)
7. **`swift test`** → 116 tests pass (104 from before + 12 new `DualSenseBatteryReaderTests`).

- [ ] **Step 3: Capture failures**

If a step does not behave as expected: stop, capture exact menu-bar state + Console.app log lines for `com.purefuncinc.FooTinderPad / DualSenseBatteryReader`, and surface to the controller before proceeding to PR. The spec or implementation may need revision — the PoC validated the basic mechanism but not every edge case.

---

## Self-review notes

- **Spec coverage** — every spec section maps to a task: pure parser + parse rules → Task 1; IOHID lifecycle / `attach`/`detach` / Get Feature Report 0x05 trigger → Task 2; `BatteryMonitor` composition + `isDualSense` gate + fallback merge → Task 3; manual smoke checklist → Task 4. Edge cases (already-in-0x31, GetReport failure, IOHIDDeviceOpen failure, multiple DualSense, non-DualSense active, malformed reports, persistent-mode side effect) are addressed by code paths in Tasks 2-3 or are documentation-only in the spec.
- **Type/name consistency** — `DualSenseBatteryReader.parse(report:)`, `attach()`, `detach()`, `current`, `onChange` consistent across tasks. `BatteryMonitor.dualsense`, `isDualSense(_:)` consistent. `BatterySuffix` cases match exactly the ones from PR #4 (`none` / `discharging(level:)` / `charging(level:)` / `full`).
- **No placeholders** — every step contains executable commands or full code. No "similar to Task N" or "TBD".
- **YAGNI** — no DualShock4, no Xbox, no UI changes, no new config knobs. Only the minimum to make BT DualSense show battery.
