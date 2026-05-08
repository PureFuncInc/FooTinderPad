# Controller Battery Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the active controller's battery level as a suffix on the menu-bar gamepad icon, with charging (`⚡`), full (`100%`), and low-battery (red, ≤20%) indicators.

**Architecture:** A new `BatteryMonitor` wrapper class (modeled on `AccessibilityGate` and `LaunchAtLogin`) owns a 30-second timer and a pure suffix-rendering helper. `AppDelegate` keeps the binding in sync with both controller activity AND accessibility state via a `rebindBattery()` helper, so revoking accessibility unbinds the timer (no race where a tick could resurrect the suffix). `MenuBar` gains one new method, `setBatterySuffix(_:)`, which writes `statusItem.button.attributedTitle`.

**Tech Stack:** Swift 5.9+, SwiftPM, AppKit (`NSStatusItem`, `NSAttributedString`, `NSColor`), GameController (`GCController`, `GCDeviceBattery`), XCTest.

**Spec:** `docs/superpowers/specs/2026-05-08-controller-battery-display-design.md`

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/FooTinderPad/System/BatteryMonitor.swift` | **new** | `BatterySuffix` enum + `BatteryMonitor` class (timer + bind/refresh/stop) + pure `suffix(level:state:)` helper |
| `Sources/FooTinderPad/UI/MenuBar.swift` | modify | Add `setBatterySuffix(_:)`; remove `button.title = ""` from `setIcon()` (title now owned by `setBatterySuffix`) |
| `Sources/FooTinderPad/AppDelegate.swift` | modify | Hold a `BatteryMonitor`; add `rebindBattery()` helper; wire `onChange` to MenuBar; rebind on `controllers.onActiveChanged` AND `accessibility.onStateChange`; refresh on `menuWillOpen`; stop in `applicationWillTerminate` |
| `Tests/FooTinderPadTests/BatteryMonitorTests.swift` | **new** | XCTest cases covering the pure helper (the only logic-dense piece) |
| `README.md` | modify | One paragraph describing the menu-bar suffix, ⚡ for charging, red ≤20% |

The `BatteryMonitor` class lives alongside other system-state wrappers (`AccessibilityGate`, `LaunchAtLogin`) under `Sources/FooTinderPad/System/`. Format / state-collapse logic stays in a `static` helper so it can be tested without constructing a `GCDeviceBattery` (Apple does not expose an init).

---

## Task 1: BatterySuffix + pure suffix helper (TDD)

This is the only logic-dense piece. Use TDD so the rounding, clamping, and state-collapse rules are nailed down before the orchestration is built around them.

**Files:**
- Create: `Tests/FooTinderPadTests/BatteryMonitorTests.swift`
- Create: `Sources/FooTinderPad/System/BatteryMonitor.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FooTinderPadTests/BatteryMonitorTests.swift` with the full test set. The tests reference `BatterySuffix` and `BatteryMonitor.suffix(level:state:)`, neither of which exists yet, so compilation will fail.

```swift
import XCTest
import GameController
@testable import FooTinderPad

final class BatteryMonitorTests: XCTestCase {

    // MARK: - Discharging

    func testDischargingMidLevel() {
        let s = BatteryMonitor.suffix(level: 0.82, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 82))
        XCTAssertFalse(s.isLow)
    }

    func testDischargingLowLevel() {
        let s = BatteryMonitor.suffix(level: 0.15, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 15))
        XCTAssertTrue(s.isLow)
    }

    func testDischargingExactlyAtThreshold() {
        let s = BatteryMonitor.suffix(level: 0.20, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 20))
        XCTAssertTrue(s.isLow, "threshold is inclusive — 20% is low")
    }

    func testDischargingJustAboveThreshold() {
        let s = BatteryMonitor.suffix(level: 0.21, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 21))
        XCTAssertFalse(s.isLow)
    }

    // MARK: - Charging

    func testChargingNotFull() {
        let s = BatteryMonitor.suffix(level: 0.50, state: .charging)
        XCTAssertEqual(s, .charging(level: 50))
        XCTAssertFalse(s.isLow)
    }

    func testChargingLowIsNotIsLow() {
        // Red is suppressed while charging — the user is already taking action.
        let s = BatteryMonitor.suffix(level: 0.10, state: .charging)
        XCTAssertEqual(s, .charging(level: 10))
        XCTAssertFalse(s.isLow)
    }

    func testChargingAtFullCollapsesToFull() {
        let s = BatteryMonitor.suffix(level: 1.0, state: .charging)
        XCTAssertEqual(s, .full)
    }

    // MARK: - Full + Unknown

    func testFullState() {
        let s = BatteryMonitor.suffix(level: 1.0, state: .full)
        XCTAssertEqual(s, .full)
    }

    func testUnknownStateAlwaysNone() {
        let s = BatteryMonitor.suffix(level: 0.5, state: .unknown)
        XCTAssertEqual(s, .none)
    }

    // MARK: - Clamping

    func testNegativeLevelClamped() {
        let s = BatteryMonitor.suffix(level: -0.1, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 0))
    }

    func testOverflowLevelClamped() {
        let s = BatteryMonitor.suffix(level: 1.5, state: .charging)
        XCTAssertEqual(s, .full)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BatteryMonitorTests`
Expected: build error (`cannot find 'BatteryMonitor' in scope`, `cannot find 'BatterySuffix' in scope`).

- [ ] **Step 3: Implement BatterySuffix + the pure helper**

Create `Sources/FooTinderPad/System/BatteryMonitor.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BatteryMonitorTests`
Expected: 11 tests pass, 0 fail.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/System/BatteryMonitor.swift Tests/FooTinderPadTests/BatteryMonitorTests.swift
git commit -m "feat(battery): add BatterySuffix + pure suffix helper

Defines the four display states (none/discharging/charging/full) with
isLow scoped to discharging only, and a static helper that clamps level
to [0,1] and collapses charging-at-100% into .full. 11 unit tests cover
each branch + clamping + threshold edges."
```

---

## Task 2: BatteryMonitor orchestration (bind / refresh / stop / timer)

The class wraps the `GCController.battery` property in a state machine: a 30-second timer drives periodic re-reads while a controller is bound, and `bind(nil)` / `stop()` tear it down. No new tests — the GameController API is not user-constructible, and the orchestration is a thin wrapper around the already-tested pure helper. Build cleanly is the only verification.

**Files:**
- Modify: `Sources/FooTinderPad/System/BatteryMonitor.swift`

- [ ] **Step 1: Add the orchestration to BatteryMonitor**

Replace the file's contents with the version below (the previous `enum BatterySuffix` and `static func suffix(level:state:)` are preserved verbatim — only the class body grows):

```swift
import Foundation
import GameController

enum BatterySuffix: Equatable {
    case none
    case discharging(level: Int)
    case charging(level: Int)
    case full

    var isLow: Bool {
        if case .discharging(let n) = self { return n <= 20 }
        return false
    }
}

final class BatteryMonitor {

    /// Polling cadence. Battery levels move slowly, and the menu re-opens trigger
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
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: clean build, no warnings about the new file.

- [ ] **Step 3: Run all tests to confirm nothing regressed**

Run: `swift test`
Expected: all existing tests + the 11 BatteryMonitor tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/FooTinderPad/System/BatteryMonitor.swift
git commit -m "feat(battery): add BatteryMonitor bind/refresh/stop + 30s timer

Wraps GCController.battery polling in a state machine: 30s repeating
timer while bound, immediate read on bind, diff-on-set so onChange only
fires when the rendered suffix changes. bind(nil) and stop() invalidate
the timer. weak controller ref + weak self in the timer block keep this
GC-friendly."
```

---

## Task 3: MenuBar.setBatterySuffix(_:)

Render the suffix as `attributedTitle` on the status-bar button. The leading space separates the title from the SF Symbol. Red is applied via `NSColor.systemRed` only for the discharging-low case.

**Files:**
- Modify: `Sources/FooTinderPad/UI/MenuBar.swift`

- [ ] **Step 1: Add `setBatterySuffix(_:)` to MenuBar**

Insert the new method right after `setIcon(_:)` (or anywhere in the public-API section — just keep it next to `setStatusLine` and `setIcon` for cohesion):

```swift
func setBatterySuffix(_ suffix: BatterySuffix) {
    guard let button = statusItem?.button else { return }
    let title: String
    let color: NSColor?
    switch suffix {
    case .none:
        title = ""
        color = nil
    case .discharging(let n):
        title = " \(n)%"
        color = (n <= 20) ? .systemRed : nil
    case .charging(let n):
        title = " ⚡\(n)%"
        color = nil
    case .full:
        title = " ⚡100%"
        color = nil
    }
    if let color {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: color]
        )
    } else {
        button.attributedTitle = NSAttributedString(string: title)
    }
}
```

- [ ] **Step 2: Remove the trailing `button.title = ""` from `setIcon(_:)`**

The current `setIcon(_:)` ends with `button.title = ""`, which clears the title every time the icon updates. Now that `setBatterySuffix` owns the title, that line would clobber the suffix on icon changes. Delete just that one line; the rest of `setIcon` is unchanged.

Find this in `Sources/FooTinderPad/UI/MenuBar.swift`:

```swift
        case .unauthorized:
            let palette = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = base?.withSymbolConfiguration(size.applying(palette))
            image?.isTemplate = false
            button.image = image
        }
        button.title = ""
    }
```

Replace with:

```swift
        case .unauthorized:
            let palette = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = base?.withSymbolConfiguration(size.applying(palette))
            image?.isTemplate = false
            button.image = image
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: all tests pass (no MenuBar tests exist — this confirms nothing else broke).

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/UI/MenuBar.swift
git commit -m "feat(menubar): render battery suffix on status item title

setBatterySuffix(_:) writes attributedTitle with a leading space so the
percentage sits cleanly to the right of the SF Symbol. Discharging at
or below 20% renders systemRed; charging adds a ⚡ prefix; .full renders
as ⚡100%; .none clears the title.

Drops the now-redundant button.title = \"\" line from setIcon — the
title is owned by setBatterySuffix from this commit forward."
```

---

## Task 4: AppDelegate wiring + rebindBattery helper

Glue everything together. Both `controllers.onActiveChanged` and `accessibility.onStateChange` route through one helper, `rebindBattery()`, which encodes the rule "bind to the active controller iff accessibility is granted." This eliminates a race where a denied state plus a pending timer tick could resurrect the suffix.

**Files:**
- Modify: `Sources/FooTinderPad/AppDelegate.swift`

- [ ] **Step 1: Add the `battery` property and the `rebindBattery()` helper**

Add the property next to the other lazy/let members (e.g., right under `private let launchAtLogin = LaunchAtLogin()`):

```swift
    private let battery = BatteryMonitor()
```

Add the helper as a new `private func` in the AppDelegate (next to `refreshMenuBarState()`):

```swift
    private func rebindBattery() {
        let target: GCController? = (accessibility.state == .granted) ? controllers.active : nil
        battery.bind(controller: target)
    }
```

- [ ] **Step 2: Wire `battery.onChange` in `applicationDidFinishLaunching`**

Find this block in `applicationDidFinishLaunching`:

```swift
        controllers.onActiveChanged = { [weak self] _ in
            self?.refreshMenuBarState()
        }
        controllers.start()
        tickLoop.start()

        refreshMenuBarState()
    }
```

Replace with:

```swift
        battery.onChange = { [weak self] suffix in
            self?.menuBar.setBatterySuffix(suffix)
        }
        controllers.onActiveChanged = { [weak self] _ in
            self?.rebindBattery()
            self?.refreshMenuBarState()
        }
        controllers.start()
        tickLoop.start()

        refreshMenuBarState()
    }
```

- [ ] **Step 3: Hook `accessibility.onStateChange` to call `rebindBattery()`**

Find this block in `applicationDidFinishLaunching`:

```swift
        accessibility.onStateChange = { [weak self] state in
            self?.refreshMenuBarState()
            if state == .denied { self?.dispatcher.drainHeldInputs() }
        }
```

Replace with:

```swift
        accessibility.onStateChange = { [weak self] state in
            self?.refreshMenuBarState()
            if state == .denied { self?.dispatcher.drainHeldInputs() }
            self?.rebindBattery()
        }
```

- [ ] **Step 4: Refresh battery on `menuWillOpen`**

Find this line in `installMenuBar()`:

```swift
        menuBar.onMenuWillOpen = { [weak self] in self?.launchAtLogin.refresh() }
```

Replace with:

```swift
        menuBar.onMenuWillOpen = { [weak self] in
            self?.launchAtLogin.refresh()
            self?.battery.refresh()
        }
```

- [ ] **Step 5: Stop the monitor in `applicationWillTerminate`**

Find this block:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        tickLoop.stop()
        controllers.stop()
        configManager.stop()
        accessibility.stop()
    }
```

Replace with:

```swift
    func applicationWillTerminate(_ notification: Notification) {
        tickLoop.stop()
        controllers.stop()
        configManager.stop()
        accessibility.stop()
        battery.stop()
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: clean build.

- [ ] **Step 7: Run all tests**

Run: `swift test`
Expected: every test (existing + new BatteryMonitor) passes.

- [ ] **Step 8: Commit**

```bash
git add Sources/FooTinderPad/AppDelegate.swift
git commit -m "feat(app): wire BatteryMonitor through AppDelegate

rebindBattery() centralizes the rule \"bind iff accessibility granted\";
both controllers.onActiveChanged and accessibility.onStateChange route
through it, closing the race where a pending tick could resurrect the
suffix after access is revoked. menuWillOpen does an immediate refresh
for snappy feedback. applicationWillTerminate now stops the monitor."
```

---

## Task 5: Manual smoke test (acceptance)

Visual confirmation against the spec's smoke checklist. No code changes. Skip steps that need hardware you do not have on hand — note them in the commit message of Task 6 if any are unverifiable.

**Files:** none.

- [ ] **Step 1: Install the build**

Run: `make clean && make install`
Expected: the freshly-built `FooTinderPad.app` is in `/Applications`, running from the menu bar.

- [ ] **Step 2: Walk the smoke checklist**

Reference: `docs/superpowers/specs/2026-05-08-controller-battery-display-design.md` § Manual smoke test.

1. **No controller** → menu bar shows the gray idle 🎮, no suffix.
2. **Connect a wireless controller (PS5 / Xbox over Bluetooth)** → within 30 s (or on next menu open), bar shows e.g. `🎮 82%`.
3. **Plug in USB-C while running** → open the menu (forces refresh) → `🎮 ⚡82%`.
4. **Charge to 100%** → `🎮 ⚡100%`.
5. **Unplug fully** → `🎮 100%` (no bolt) on next refresh.
6. **Drain to ≤20%** → percentage turns red.
7. **Disconnect controller** → suffix gone, icon back to gray idle.
8. **Connect a controller that reports `.unknown`** (e.g., some wired generic HID adapters, if available) → `🎮` with no suffix.
9. **Revoke Accessibility permission** (System Settings → Privacy & Security → Accessibility, toggle FooTinderPad off) → bar shows the red unauthorized icon, no suffix. Re-grant → suffix returns on next refresh.

- [ ] **Step 3: If anything fails, capture the failure**

If a step does not behave as expected: note exactly which step, what was shown, and what was expected. Stop and surface to the user before proceeding to Task 6 — the spec may need revision rather than the implementation.

---

## Task 6: README paragraph

Document the user-visible behavior. Keep it short and slot it near the existing menu-bar / status-icon discussion.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Insert the new paragraph**

Add this paragraph to `README.md` under a new heading `## Battery indicator` (place it after the `## PS5 示範設定 (易上手版)` section, before `## Launch at Login`):

```markdown
## Battery indicator

當控制器連線且回報電量時, menu bar 圖示右側會顯示百分比, 例如 `🎮 82%`。充電中加上 `⚡` 前綴 (`🎮 ⚡82%`), 充滿時顯示 `🎮 ⚡100%`。放電時若降到 20% 或以下, 數字轉為紅色提醒充電 (充電中的低電量不轉紅, 因為已在充電)。控制器未提供電量資訊 (有線通用 HID, 部分第三方型號) 時不顯示百分比, 只留 icon。
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): document menu-bar battery indicator behavior"
```

---

## Self-review notes

- **Spec coverage** — every spec section maps to a task: pure helper + enum (Task 1), orchestration + timer (Task 2), MenuBar render (Task 3), AppDelegate wiring including the accessibility-revocation race fix (Task 4), manual smoke checklist (Task 5), README (Task 6).
- **Type consistency** — `BatterySuffix.discharging(level:)` (labeled), `BatteryMonitor.suffix(level:state:)`, `BatteryMonitor.bind(controller:)`, `BatteryMonitor.refresh()`, `BatteryMonitor.stop()`, `MenuBar.setBatterySuffix(_:)`, `AppDelegate.rebindBattery()` — all referenced consistently across tasks.
- **No placeholders** — every code block is complete; no "TBD" / "implement later" / "similar to Task N".
- **Edge cases** — clamping (Task 1 tests), charging-at-100% collapse (Task 1), accessibility race (Task 4 wiring), stop on terminate (Task 4 step 5).
