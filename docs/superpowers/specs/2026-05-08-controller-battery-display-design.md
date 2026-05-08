# Controller Battery Display — Design

## Goal

Surface the active controller's remaining battery as a short suffix on the menu bar (`🎮 82%`), so a user driving macOS through a wireless gamepad can see when to plug in before the controller dies mid-session — losing input would also lose the means to plug it in.

## Scope

- **In scope**: a percentage suffix appended to the existing menu-bar icon; visual differentiation for charging (`⚡` prefix) and full (`100%`); red text when discharging at or below 20%; periodic refresh while a controller is connected; refresh on menu open; clean teardown on disconnect / quit.
- **Out of scope**: a config knob to disable the feature or tune the 20% threshold (YAGNI — surfaces add complexity, the values are sensible defaults); macOS notifications on low battery (the user explicitly preferred passive red-text indication); duplicating the percentage inside the dropdown's status line (single source of truth on the bar); battery for non-active controllers in the stack (the existing active-controller model already collapses to one).

## User-facing model

The menu bar already shows a `gamecontroller` SF Symbol; the change adds an optional text suffix to the right of it. With no controller, or when the active controller does not report a battery level, nothing changes from today.

**Display rules** — derived purely from `GCDeviceBattery.batteryState` and `batteryLevel`:

| Condition | Menu bar | Color |
|---|---|---|
| `active == nil` | `🎮` (idle gray, current behavior) | — |
| `battery == nil` or `state == .unknown` | `🎮` (operational template, no suffix) | — |
| `state == .discharging`, level > 20% | `🎮 82%` | template / system |
| `state == .discharging`, level ≤ 20% | `🎮 15%` | **systemRed** |
| `state == .charging`, level < 100% | `🎮 ⚡82%` | template (red is suppressed while charging) |
| `state == .charging` with level ≥ 99.5% rounded to 100, or `state == .full` | `🎮 ⚡100%` | template |

**Percentage format**: `Int((level * 100).rounded())` after clamping `level` to `[0, 1]`. No decimals.

**Charging-but-low is intentionally not red.** The red threshold exists to prompt action (plug in); if the user already plugged in, the alert is noise and the value is recovering.

**Dropdown status line stays as-is** — `vendorName` only, no battery duplication. Reasoning: the menu bar shows the value continuously, repeating it inside the dropdown adds noise and a second place to keep in sync.

**Accessibility-denied state takes precedence** — when accessibility is `.denied`, the icon goes red (current behavior) and the suffix is forced to empty so the bar does not show two competing signals.

## Architecture

A `BatteryMonitor` class in `Sources/FooTinderPad/System/`, modeled after `AccessibilityGate` and `LaunchAtLogin`: owns its state, exposes an `onChange` callback, has no UI dependencies. AppDelegate wires it to `MenuBar`.

```swift
enum BatterySuffix: Equatable {
    case none                          // unknown / no battery / no controller
    case discharging(level: Int)       // 0...100
    case charging(level: Int)          // 0...100, never 100 (use .full)
    case full                          // rendered as "⚡100%"

    var isLow: Bool {
        if case .discharging(let n) = self { return n <= 20 }
        return false
    }
}

final class BatteryMonitor {
    private(set) var current: BatterySuffix = .none
    var onChange: ((BatterySuffix) -> Void)?

    func bind(controller: GCController?)   // nil = unbind + stop timer
    func refresh()                         // force re-read; cheap
    func stop()                            // tear down for app quit
}
```

The state machine is small; the real logic lives in a pure helper that's the unit-test target:

```swift
extension BatteryMonitor {
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

The instance method `refresh()` reads the bound controller's `battery` property, calls the pure helper, diffs against `current`, and fires `onChange` only on change — so the 30-second tick does not redraw the menu bar every 30 seconds when nothing moved.

### Why an enum, not `(level: Int?, isCharging: Bool)`

`.none`, `.full`, `.charging`, `.discharging` are categorically different states with different rendering and different rules (e.g., red text only applies to `.discharging`). An enum makes the renderer's switch exhaustive and prevents nonsense states like "level 100 + discharging + charging at the same time."

### Timer

`Timer.scheduledTimer(withTimeInterval: 30, repeats: true)`, started inside `bind(controller:)` when a non-nil controller is passed and invalidated on `bind(controller: nil)` or `stop()`. 30 seconds is chosen as a balance: battery levels move slowly enough that finer polling is wasted work, but coarser cadence makes a session feel stale. The bar is also refreshed on `menuWillOpen` for instant feedback on user-initiated checks.

We do not subscribe to NSWorkspace sleep/wake notifications. After wake, the next 30-second tick (or the next menu open) corrects any stale value; the additional code path is not justified by the brief flash of stale text.

### MenuBar API

```swift
// UI/MenuBar.swift
func setBatterySuffix(_ suffix: BatterySuffix)
```

Internally, `setBatterySuffix` writes `statusItem.button.attributedTitle`:

| Suffix | Title string | Color |
|---|---|---|
| `.none` | `""` | n/a |
| `.discharging(n)` where `n > 20` | `" \(n)%"` | default (template-tinted) |
| `.discharging(n)` where `n ≤ 20` | `" \(n)%"` | `NSColor.systemRed` |
| `.charging(n)` | `" ⚡\(n)%"` | default |
| `.full` | `" ⚡100%"` | default |

The leading space separates the title from the SF Symbol. The current `setIcon()` method's trailing `button.title = ""` line is removed, since `setBatterySuffix` is now the only writer of the title.

### AppDelegate wiring

The bind target is always "the currently active controller, AND only if accessibility is granted." Both signals can change independently, so AppDelegate exposes a small helper and calls it from both observers:

```swift
private let battery = BatteryMonitor()

private func rebindBattery() {
    let target: GCController? = (accessibility.state == .granted) ? controllers.active : nil
    battery.bind(controller: target)
}

// applicationDidFinishLaunching
battery.onChange = { [weak self] suffix in
    self?.menuBar.setBatterySuffix(suffix)
}

controllers.onActiveChanged = { [weak self] _ in
    self?.rebindBattery()
    self?.refreshMenuBarState()
}

accessibility.onStateChange = { [weak self] state in
    self?.refreshMenuBarState()
    if state == .denied { self?.dispatcher.drainHeldInputs() }
    self?.rebindBattery()
}

menuBar.onMenuWillOpen = { [weak self] in
    self?.launchAtLogin.refresh()
    self?.battery.refresh()
}

// applicationWillTerminate
battery.stop()
```

Binding to `nil` invalidates the timer and fires `onChange(.none)` — so the menu bar suffix clears automatically when accessibility is revoked, with no separate "force `.none`" branch in `refreshMenuBarState()` and no race where a pending timer tick could resurrect the suffix on a denied state.

### Flow

```
App launch
  → AppDelegate inits BatteryMonitor (current = .none)
  → MenuBar.install() leaves the title empty
  → ControllerManager.start() may immediately fire onActiveChanged

Controller connects (or initial adopt)
  → ControllerManager.onActiveChanged(c)
  → AppDelegate calls battery.bind(controller: c)
       → reads battery once via suffix(level:state:)
       → starts 30 s timer
       → if suffix != .none, onChange fires
  → MenuBar.setBatterySuffix(...)

Every 30 s
  → timer tick → refresh() → re-read → diff → onChange iff changed

User opens menu
  → menuWillOpen → battery.refresh() (cheap, same diff path)

Controller disconnects (or switches)
  → onActiveChanged(next-or-nil) → battery.bind(controller: ...)
       → previous timer invalidated
       → if nil: suffix = .none, onChange fires
       → if next: read + start timer + onChange iff changed

App quits
  → applicationWillTerminate → battery.stop() → timer invalidated
```

## New / modified files

| File | Change |
|---|---|
| `Sources/FooTinderPad/System/BatteryMonitor.swift` | New file. `BatterySuffix` enum, `BatteryMonitor` class, pure `suffix(level:state:)` helper. |
| `Sources/FooTinderPad/UI/MenuBar.swift` | Add `setBatterySuffix(_:)`. Remove the trailing `button.title = ""` line in `setIcon()` since the title is now owned by `setBatterySuffix`. |
| `Sources/FooTinderPad/AppDelegate.swift` | Add `private let battery = BatteryMonitor()`; wire `onChange` to `MenuBar.setBatterySuffix`; have `controllers.onActiveChanged` and `menuWillOpen` call into the monitor; force `.none` in the accessibility-denied branch of `refreshMenuBarState()`; call `battery.stop()` in `applicationWillTerminate`. |
| `Tests/FooTinderPadTests/BatteryMonitorTests.swift` | New file. Cases for `suffix(level:state:)`. |
| `README.md` | One paragraph describing the menu-bar suffix, the ⚡ prefix while charging, and the red ≤20% indication. |

`Info.plist`, `Makefile`, `Package.swift` — unchanged. `GCDeviceBattery` is part of the GameController framework already linked.

## Edge cases

1. **Controller connected but `battery == nil`** (third-party HID, some wired adapters) — pure helper is not even called; `BatteryMonitor.refresh()` short-circuits to `.none`. Bar shows icon only.
2. **`batteryState == .unknown`** (Apple's documented "no info available" value) — `.none`. Same visual as no battery at all.
3. **`batteryLevel < 0` or `> 1`** — clamped via `max(0, min(1, level))` before rounding. Prevents `-1%` or `101%` ever surfacing.
4. **Charging that just hit 100%** — pure helper collapses `.charging(level: 100)` to `.full`. Avoids a one-tick `⚡100%` from `.charging` and a separate `⚡100%` from `.full`; both render identically anyway.
5. **Charging at very low level** (`⚡5%`) — `.isLow` is false (it's only true for `.discharging`). Stays template color, no red.
6. **Multiple controllers in the active stack** — `ControllerManager` already serializes to one active at a time. `bind(controller:)` follows that single source. Switching controllers tears down the previous binding implicitly.
7. **Sleep/wake** — `Timer` pauses while the host sleeps. After wake, the next 30 s tick (or the next `menuWillOpen`) refreshes. Brief stale text accepted; no `NSWorkspace.willSleepNotification` listener.
8. **Accessibility denied while a controller is connected** — `accessibility.onStateChange` calls `rebindBattery()`, which passes `nil` to `bind(controller:)`; the timer is invalidated and `onChange(.none)` fires, clearing the suffix. Critically, this also closes the race where a pending 30-second tick could otherwise resurrect the suffix after the icon turned red. When the user re-grants, `rebindBattery()` runs again with the still-active controller and the suffix returns on the next read.
9. **App quit during a timer tick** — `stop()` invalidates the timer and clears `onChange` (defensive `onChange = nil` to avoid a final callback after MenuBar tear-down). `applicationWillTerminate` is also where we already stop the controllers and tick loop.
10. **`@unknown default` from `GCDeviceBattery.State`** — falls through to `.none` so future Apple-added states surface as "no info" rather than misrendering.
11. **Rapid charge-state flips** (charger contact bouncing) — diff-on-set ensures we only fire `onChange` when the rendered string would actually differ; `attributedTitle` writes are still cheap on AppKit but this avoids menu-bar flicker on pathological inputs.

## Tests

`Tests/FooTinderPadTests/BatteryMonitorTests.swift` — covers the pure helper. `GCDeviceBattery` is not user-constructible, so tests pass `(level: Float, state: GCDeviceBattery.State)` directly to the static helper rather than mocking the framework type.

- `testDischargingMidLevel` — `(0.82, .discharging)` → `.discharging(82)`, `isLow == false`
- `testDischargingLowLevel` — `(0.15, .discharging)` → `.discharging(15)`, `isLow == true`
- `testDischargingExactlyAtThreshold` — `(0.20, .discharging)` → `.discharging(20)`, `isLow == true` (threshold is inclusive)
- `testDischargingJustAboveThreshold` — `(0.21, .discharging)` → `isLow == false`
- `testChargingNotFull` — `(0.50, .charging)` → `.charging(50)`, `isLow == false`
- `testChargingLowIsNotIsLow` — `(0.10, .charging)` → `.charging(10)`, `isLow == false` (red is suppressed while charging)
- `testChargingAtFullCollapsesToFull` — `(1.0, .charging)` → `.full`
- `testFullState` — `(1.0, .full)` → `.full`
- `testUnknownStateAlwaysNone` — `(0.5, .unknown)` → `.none`
- `testNegativeLevelClamped` — `(-0.1, .discharging)` → `.discharging(0)`
- `testOverflowLevelClamped` — `(1.5, .charging)` → `.full`

Not unit-tested (matches `AccessibilityGate`/`LaunchAtLogin`'s pragmatic stance):

- `Timer` lifecycle, `bind`/`refresh`/`stop` orchestration — would require `GCController` test doubles or a protocol layer that buys nothing for one production caller.
- `NSStatusItem` rendering — visual; covered by manual smoke test.

### Manual smoke test (acceptance checklist)

1. `make install`. With no controller paired: menu bar shows the gray idle 🎮 icon, no suffix.
2. Connect a PS5 DualSense over Bluetooth. Within 30 seconds (or as soon as the menu is opened), the bar shows `🎮 82%` (or whatever the current level is).
3. Plug in the controller via USB-C while the app is running. Open the menu to force a refresh — the bar shows `🎮 ⚡82%`.
4. Let it charge to 100%. Bar shows `🎮 ⚡100%`.
5. Unplug. Bar shows `🎮 100%` (no bolt) — within 30 s or on next menu open.
6. Drain to ≤20%. The percentage turns red.
7. Power the controller off (or move it out of range). Bar reverts to gray idle 🎮, suffix gone.
8. Connect a wired Xbox-style controller that reports `.unknown`. Bar shows `🎮` (no suffix).
9. Revoke Accessibility permission while connected. Bar shows the red unauthorized icon, no suffix. Re-grant — suffix returns on next refresh.

## Out of scope (future)

- Config flag to disable the feature or tune the 20% red threshold.
- macOS UserNotifications when crossing the threshold.
- Showing the battery for non-active controllers in the stack.
- Reacting to system sleep/wake events for an immediate refresh on wake (rather than waiting for the next tick or menu open).
- Persisting last-known level across app restarts (irrelevant — controllers re-report on connect).
