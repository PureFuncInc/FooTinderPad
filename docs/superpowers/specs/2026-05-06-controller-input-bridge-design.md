# Controller Input Bridge — Design

**Date:** 2026-05-06
**Status:** Approved (brainstorming complete; awaiting implementation plan)
**Project:** FooTinderPad

## Goal

Turn an Xbox or DualSense (PS5) controller into a mouse + keyboard input device for macOS, using `GameController.framework` to read the device and `CGEvent` posting to synthesize host input. Behavior is configured via a JSON file users can edit live.

Functional scope:
- Sticks drive mouse motion and scroll.
- Buttons / d-pad / triggers trigger single keys, modifier-only keys, key combos (e.g. `Alt+Return`), or mouse buttons.
- Tunable parameters: stick deadzone, mouse speed, scroll speed.
- Hot-reload of config without restart.
- Last-connected-controller wins when multiple are paired.

Non-goals (v1):
- Per-app profiles, on-the-fly profile switching.
- Touchpad / share / mute buttons (DualSense extras).
- Pause/resume input forwarding.
- Background daemon split — stays a single menu-bar app.

---

## § 1. Architecture

### Process model

Single-process AppKit menu-bar app (`LSUIElement = true`, already configured). All work runs on the main thread. CGEvent posting is non-blocking; no background queues are needed.

### Component map

```
GameController.framework  →  ControllerManager  ─┐
                                                  ├→  InputDispatcher  →  CGEvent posts
                  CVDisplayLink (TickLoop)  ─────┘                          (mouse / scroll / key)
                                                  ↑
                            ConfigManager  ───────┘  (hot-reload via DispatchSource)
```

### File layout

```
Sources/FooTinderPad/
  main.swift                         entry point (~4 lines)
  AppDelegate.swift                  composition root
  Config/
    Config.swift                     Codable model + ResolvedConfig + validation
    ConfigManager.swift              load + DispatchSource watcher + atomic swap
    DefaultConfig.swift              fallback in-memory default if bundle resource missing
  Input/
    KeyParser.swift                  "Alt+Return" → (CGKeyCode?, [ModifierKey])
    KeySynthesizer.swift             CGEvent keyDown/Up + modifier ref-count
    MouseSynthesizer.swift           CGEvent mouseMoved / scroll / button
    StickProcessor.swift             deadzone + linear curve + fractional accumulator
    InputDispatcher.swift            routes controller events to synthesizers
  Controller/
    ControllerManager.swift          GCController discovery + last-connected-wins
    TickLoop.swift                   CVDisplayLink driven tick
  System/
    AccessibilityGate.swift          AXIsProcessTrusted + onboarding NSAlert
    Paths.swift                      ~/Library/Application Support/...
  UI/
    MenuBar.swift                    status item + Reload / Reveal / About / Quit

Resources/
  DefaultConfig.json                 bundled into .app; copied on first launch

Tests/FooTinderPadTests/
  KeyParserTests.swift
  StickProcessorTests.swift
  ConfigParserTests.swift
  ModifierRefCountTests.swift
```

### Threading

- `applicationDidFinishLaunching` builds the object graph on the main thread.
- `GCController` notifications fire on main thread (default).
- CVDisplayLink callback fires on a system thread; we hop to main via `DispatchQueue.main.async` before doing any work, so all controller / config / synthesizer state lives on a single thread.
- `ConfigManager`'s `DispatchSource` is configured with `queue: .main` so reload also lands on main.

---

## § 2. Stick Processing

### Sampling

Sticks use `valueChangedHandler` only to **store** the latest x/y into atomic state on `ControllerManager`. The `TickLoop` is what reads stick state and emits motion. This decouples emit cadence from controller report rate, prevents event flooding, and keeps motion smooth.

### Deadzone (circular)

Use vector magnitude rather than per-axis comparison so the dead region is a circle, not a square:

```
let mag = sqrt(x*x + y*y)
if mag < deadzone {
    accumX = 0; accumY = 0
    return
}
let n = (mag - deadzone) / (1 - deadzone)   // 0..1, normalized magnitude after deadzone
let scale = n / mag
let nx = x * scale
let ny = y * scale
```

### Speed scaling (refresh-rate-independent)

```
mouse:  dxPx = nx * mouseSpeed * tickScale
        dyPx = -ny * mouseSpeed * tickScale     // invert Y: stick up == cursor up
scroll: dxLn = nx * scrollSpeed * tickScale
        dyLn = ny * scrollSpeed * tickScale     // do not invert; OS natural-scroll handles direction
```

`tickScale = dt * 60`, where `dt` is seconds between this tick and the previous one (computed from `CVTimeStamp.outputTime`). With `mouseSpeed = 15`, full deflection produces 900 px/sec regardless of whether the display runs at 60 Hz or 120 Hz (ProMotion).

### Fractional accumulator

CGEvent mouse deltas are integers. Slow stick deflections produce sub-pixel velocity that would round to zero. Each axis carries an accumulator:

```
accumX += dxPx
let emitX = trunc(accumX)
accumX -= emitX
post mouseMoved(by: emitX)   // scroll uses an analogous accumulator
```

Reset `accumX = accumY = 0` whenever `mag < deadzone` (returning to neutral should not bank up motion to release later).

### Multiple sticks driving the same role

Configuration allows both sticks to drive `"mouse"` (or both `"scroll"`). Deltas from each stick are computed independently and summed before emit. No special case; not prevented.

### CGEvent specifics

- **Mouse move**: read current cursor with `CGEvent(source: nil)?.location`, add `(emitX, emitY)`, then `CGEventCreateMouseEvent(.mouseMoved, newPos, .left)` and post to `cghidEventTap`. Re-reading current location each tick prevents drift if the user (or another tool) moves the mouse out from under us.
- **Scroll**: `CGEventCreateScrollWheelEvent(.line, axisCount: 2, wheel1: emitYln, wheel2: emitXln)`, post to `cghidEventTap`. Line units; OS handles natural-scroll, acceleration, and per-app smoothing.
- **Mouse buttons**: `mouseDown` / `mouseUp` events posted at the current cursor location.

---

## § 3. Bindings & Key Parser

### Naming dictionary (PC-style; macOS aliases accepted)

**Modifier tokens** (case-insensitive):

| Token | Aliases | macOS keyCode | NSEvent flag |
|---|---|---|---|
| `Ctrl` | `Control` | 0x3B left / 0x3E right | maskControl |
| `Alt` | `Option`, `Opt` | 0x3A left / 0x3D right | maskAlternate |
| `Shift` | — | 0x38 left / 0x3C right | maskShift |
| `Win` | `Cmd`, `Command` | 0x37 left / 0x36 right | maskCommand |
| `Fn` | — | (flag only, no keyCode) | maskSecondaryFn |

Side-specific variants: `LeftCtrl` / `RightCtrl` / `LeftAlt` / `RightAlt` / `LeftShift` / `RightShift` / `LeftWin` / `RightWin`. When unspecified, the left-side keyCode is used.

**Main keys**:
- Letters: `A`–`Z` (case-insensitive)
- Digits: `0`–`9`
- Function keys: `F1`–`F20`
- Arrows: `Up` / `Down` / `Left` / `Right`
- Editing: `Space`, `Return`, `Tab`, `Escape`, `Backspace`, `Delete` (= Forward Delete), `Home`, `End`, `PageUp`, `PageDown`
- Punctuation: `Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`, `Grave`

**`Delete` deliberately maps to Forward Delete (keyCode 0x75)**, following PC convention. Use `Backspace` (keyCode 0x33) for the large delete key on macOS keyboards.

### Parsing

Input string is split on `+`, tokens are trimmed and lower-cased before lookup.

- All-but-last tokens must resolve to modifiers; the last token is the main key.
- Single-token strings that resolve to a modifier produce a **modifier-only** binding (no main key).
- Unknown tokens, empty tokens, trailing `+`, or a non-modifier appearing in a non-final position are parse errors.
- Parse errors at config load → that binding becomes `.none` and a warning is logged. Runtime never sees an unparsed key string.

### Modifier ref-counting

Two bindings can share a modifier (e.g. `Alt+Return` and `Alt+Tab`). When both are pressed simultaneously and one releases, the modifier must remain held for the other.

`KeySynthesizer` maintains `[ModifierKey: Int]`:

- `acquire(mod)`: `count[mod] += 1`; if transitioning `0 → 1`, post `keyDown(mod)`.
- `release(mod)`: `count[mod] -= 1`; if transitioning `1 → 0`, post `keyUp(mod)`. Releasing when count is already 0 is a no-op + log (defensive against bug-induced underflow).
- Main keys are not ref-counted. If two bindings share a main key and both fire, the duplicate keyDown/keyUp pair is forwarded as-is — OS behavior is acceptable and not worth the extra state.

### Per-binding semantics

| Binding | On press | On release |
|---|---|---|
| `{type: "key", key: "Backspace"}` | keyDown(Backspace) | keyUp(Backspace) |
| `{type: "key", key: "Alt+Return"}` | acquire(Alt); keyDown(Return) | keyUp(Return); release(Alt) |
| `{type: "key", key: "RightShift"}` | acquire(RightShift) | release(RightShift) |
| `{type: "mouseButton", button: "left"\|"right"\|"middle"}` | mouseDown(button) at current cursor | mouseUp(button) |
| `{type: "none"}` | no-op | no-op |

### Triggers (analog → button)

`leftTrigger.value` and `rightTrigger.value` are 0.0–1.0. Hysteresis binarization:

- Rising past `0.55` → fire **press** (call binding's press handler once).
- Falling past `0.45` → fire **release**.
- Between the two thresholds, state is held.

Thresholds are not user-configurable in v1.

### Controller mapping

| config key | Xbox | DualSense | GCExtendedGamepad path |
|---|---|---|---|
| buttonA | A | × | `buttonA` |
| buttonB | B | ○ | `buttonB` |
| buttonX | X | □ | `buttonX` |
| buttonY | Y | △ | `buttonY` |
| leftShoulder | LB | L1 | `leftShoulder` |
| rightShoulder | RB | R1 | `rightShoulder` |
| leftTrigger | LT | L2 | `leftTrigger` |
| rightTrigger | RT | R2 | `rightTrigger` |
| leftThumbstickButton | LS | L3 | `leftThumbstickButton` |
| rightThumbstickButton | RS | R3 | `rightThumbstickButton` |
| dpadUp / Down / Left / Right | D-pad | D-pad | `dpad.up` / `down` / `left` / `right` |

DualSense touchpad / share / mute / mic buttons are not bound in v1.

---

## § 4. Config & Hot Reload

### Path

`~/Library/Application Support/FooTinderPad/config.json`, resolved via `FileManager.default.url(for: .applicationSupportDirectory, ...)`. Intermediate directories are created on first launch.

The repo's existing root `config.json` becomes `Resources/DefaultConfig.json`, bundled into the `.app`. On first launch we copy it to the user-writable path. If the bundle resource is somehow missing, `DefaultConfig.swift` provides the same content as a hard-coded fallback.

### Schema (Codable)

```swift
struct Config: Codable {
    var deadzone: Double          // [0.0, 0.49]; default 0.15
    var mouseSpeed: Double        // > 0; default 15
    var scrollSpeed: Double       // > 0; default 5
    var leftStick: StickRole      // default .mouse
    var rightStick: StickRole     // default .scroll
    var bindings: [String: Binding]
}

enum StickRole: String, Codable { case mouse, scroll, none }

enum Binding: Codable {           // tagged union by "type"
    case key(String)              // raw spec string, parsed at load time
    case mouseButton(MouseButton)
    case none
}

enum MouseButton: String, Codable { case left, right, middle }
```

Whitelisted binding keys: the 14 names in the controller mapping table above.

### Validation (at load)

1. `deadzone` clamped to `[0.0, 0.49]`; out-of-range value logged as warning.
2. `mouseSpeed`, `scrollSpeed` must be `> 0`; otherwise replaced with defaults (15, 5) + warning.
3. Each `Binding.key` string parsed via `KeyParser` into a `ResolvedBinding`. Failures: that binding becomes `.none` + warning naming the offending button and reason.
4. Bindings whose key is not in the whitelist: dropped + warning.
5. Missing binding keys: treated as `.none`. Users do not need to write all 14 entries.

### Resolved runtime model

```swift
struct ResolvedConfig {
    let deadzone: Double
    let mouseSpeed: Double
    let scrollSpeed: Double
    let leftStick: StickRole
    let rightStick: StickRole
    let bindings: [ControllerButton: ResolvedBinding]
}

enum ResolvedBinding {
    case key(mainKey: CGKeyCode?, modifiers: [ModifierKey])  // mainKey nil = modifier-only
    case mouseButton(MouseButton)
    case none
}
```

Pre-resolving means the hot path never calls the parser.

### Hot reload

`ConfigManager` opens the config file with `open(O_EVTONLY)` and creates `DispatchSource.makeFileSystemObjectSource(fileDescriptor:, eventMask: [.write, .rename, .delete], queue: .main)`.

- All three event types are watched: editors that write atomically (vim, VSCode) replace the file via rename, which closes our fd. On `.rename` or `.delete` we close and re-open the fd against the same path, then re-arm the source.
- Debounce: an event schedules a reload via `DispatchQueue.main.asyncAfter(deadline: .now() + 0.1)`. If another event arrives inside the window, the previous work item is cancelled and rescheduled. Avoids double-reload from editors that write multiple times per save.
- On reload: parse + validate. On success, swap the active `ResolvedConfig` reference under a lock. On failure, log and keep the previous config.
- On config swap, **drain held inputs**: release every modifier currently held by the ref-count table, and any held main key / mouse button. This prevents a stale `Alt-held` state if the user's edit removed the binding that was still pressing it.

Manual `Reload Config` menu item performs the same load+swap+drain path without waiting for a filesystem event.

### Error matrix

| Situation | Behavior |
|---|---|
| First launch, AppSupport directory not writable | Log error; fall back to in-memory default config; menu bar status line shows `⚠ Config not persisted`. |
| Config JSON parse error on first load | Use in-memory default + warning. |
| Config JSON parse error on hot reload | Keep previous config + warning. |
| Validation failure (negative deadzone, etc.) | Field-by-field clamp / default + warning per field. |
| Unknown button name in `bindings` | Drop that entry + warning. |
| Unparsable binding key string | That binding becomes `.none` + warning. |

All warnings go to `os.Logger` (subsystem `com.purefuncinc.FooTinderPad`), visible in Console.app.

---

## § 5. Lifecycle & UX

### Launch sequence (`applicationDidFinishLaunching`)

1. `installEditMenu()` (existing).
2. `setupMenuBar()` (existing, extended with status line + Reload + Reveal items).
3. `configManager = ConfigManager(); configManager.start()` — ensures AppSupport dir exists, copies `DefaultConfig.json` if needed, parses, starts `DispatchSource`.
4. `accessibilityGate.checkAndPromptIfNeeded()`.
5. `controllerManager = ControllerManager()` — subscribes to `GCController.didConnectNotification` / `didDisconnectNotification`, then iterates `GCController.controllers()` to wire any controller already paired before launch.
6. `inputDispatcher = InputDispatcher(config: configManager, ...)` — registers itself with `controllerManager` for button / stick callbacks.
7. `tickLoop = TickLoop(...); tickLoop.start()`.
8. Menu bar binds itself to status changes from `accessibilityGate` and `controllerManager`.

### Accessibility gate

```swift
func checkAndPromptIfNeeded() {
    if AXIsProcessTrusted() { state = .granted; return }
    state = .denied

    let alert = NSAlert()
    alert.messageText = "FooTinderPad needs Accessibility permission"
    alert.informativeText = "Grant access in System Settings → Privacy & Security → Accessibility, then re-launch FooTinderPad."
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Quit")
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    NSApp.terminate(nil)
}
```

We deliberately do **not** use `AXIsProcessTrustedWithOptions(prompt: true)` — its native prompt is unreliable for `LSUIElement` apps without a Dock icon.

A 5-second `Timer` re-polls `AXIsProcessTrusted()` for the lifetime of the process. State changes update the menu bar icon color. Polling is simpler than listening for distributed-notification updates and the cost is negligible.

### Controller selection (last-connected-wins)

```swift
class ControllerManager {
    private(set) var active: GCController?
    private var stack: [GCController] = []   // connection history; last == active

    func didConnect(_ c: GCController) {
        guard c.extendedGamepad != nil else { return }
        stack.append(c)
        switchTo(c)
    }
    func didDisconnect(_ c: GCController) {
        stack.removeAll { $0 === c }
        switchTo(stack.last)
    }
    private func switchTo(_ c: GCController?) {
        unwireCurrentHandlers()
        active = c
        if let c { wireHandlers(c) }
    }
}
```

Wiring an active controller's `extendedGamepad`:
- 12 binary inputs — A/B/X/Y, leftShoulder, rightShoulder, leftThumbstickButton, rightThumbstickButton, plus the 4 d-pad directions — each `valueChangedHandler { _, _, pressed in dispatcher.handleButton(name, pressed) }`.
- Two sticks: `valueChangedHandler { _, x, y in dispatcher.updateStick(name, x, y) }` — updates only.
- Two triggers (analog): `valueChangedHandler { _, value, _ in dispatcher.handleTrigger(name, value) }` — hysteresis binarization happens inside `InputDispatcher`.

When `switchTo` runs, the previous controller's handlers are nilled out, and any held inputs from that controller are drained (same modifier / main-key / mouse-button release path used by config swap).

### TickLoop

`CVDisplayLink` synced to the main display:

```swift
CVDisplayLinkCreateWithActiveCGDisplays(&link)
CVDisplayLinkSetOutputCallback(link, { _, _, outputTime, _, _, ctx in
    let lp = Unmanaged<TickLoop>.fromOpaque(ctx!).takeUnretainedValue()
    DispatchQueue.main.async { lp.tick(outputTime: outputTime.pointee) }
    return kCVReturnSuccess
}, ...)
CVDisplayLinkStart(link)
```

`tick` computes `dt` from the time delta to the previous `outputTime`, then asks `InputDispatcher` to sample stick state. When `controllerManager.active == nil`, `tick` returns early.

### Menu bar

**Icon color** (highest condition wins):

| State | Icon color | Condition |
|---|---|---|
| Red | Accessibility not granted | `accessibilityGate.state != .granted` |
| Gray | No controller connected | granted && `controllerManager.active == nil` |
| White | Operational | granted && `controllerManager.active != nil` |

Icon symbol stays as the existing `square.stack.3d.up` SF Symbol.

**Menu items** (top to bottom):

- Status line (disabled): one of `No controller`, `<controller name>`, `⚠ Accessibility not granted`, `⚠ Config not persisted`. Multiple status lines may stack when more than one warning applies.
- ─
- `Reload Config` (⌘R)
- `Reveal Config in Finder`
- ─
- `About FooTinderPad`
- `Quit` (⌘Q)

`Reveal Config in Finder` calls `NSWorkspace.shared.activateFileViewerSelecting([Paths.configURL])`. `Reload Config` calls `configManager.reloadNow()`.

---

## § 6. Testing

### What is unit-testable vs not

| Unit-testable (pure logic) | Manual / device-dependent |
|---|---|
| `KeyParser` | `ControllerManager` (real `GCController`) |
| `StickProcessor` | `TickLoop` (real `CVDisplayLink`) |
| `KeySynthesizer` modifier ref-count state machine | `AccessibilityGate` (real `AXIsProcessTrusted`) |
| `Config` parse + validate | Actual `CGEvent` post side effects |

### Abstractions to enable testing

```swift
protocol EventSink {
    func mouseMove(deltaX: Double, deltaY: Double)
    func mouseButton(_ b: MouseButton, down: Bool)
    func scroll(deltaX: Double, deltaY: Double)
    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags)
}
```

`InputDispatcher` depends on `EventSink`. Production injects `CGEventSink`; tests inject a `RecordingSink` that captures every call into `[Action]` for assertion. Similarly, `ControllerManager` and `TickLoop` are abstracted behind `protocol ControllerSource` and `protocol Ticker`, with test fakes that drive synthetic input.

### Test cases

**`KeyParserTests`**
- `"Up"` → main = upArrow keyCode, mods = []
- `"Alt+Return"` → main = return keyCode, mods = [.alt]
- `"Ctrl+Shift+4"` → main = "4" keyCode, mods = [.ctrl, .shift]
- `"option+return"` (lowercase + alias) → equivalent to `Alt+Return`
- `"win+space"` → mods = [.cmd]
- `"RightShift"` → main = nil, mods = [.rightShift]
- `"Backspace"` → keyCode 0x33; `"Delete"` → keyCode 0x75
- Errors: `""`, `"Foo"`, `"Alt+"`, `"Alt+Foo"`, `"A+B"` all produce nil/throw.

**`StickProcessorTests`**
- Circular deadzone: `(0.1, 0.1)` mag ≈ 0.141 < 0.15 → all zero.
- Edge normalization: `(1, 0)` at `mouseSpeed=15`, `tickScale=1` → emit `15` px.
- Accumulator: 10 ticks of `dx=0.4` → total 4 px emitted across the run.
- Reset: dropping into deadzone clears `accumX` / `accumY`.
- Y inversion: stick `(0, +1)` → `dy < 0`.
- tickScale: `dt = 1/120` → emits half of `mouseSpeed`; `dt = 1/60` → emits full `mouseSpeed`.

**`ModifierRefCountTests`**
- acquire(Alt) ×1 → 1× keyDown(Alt); release ×1 → 1× keyUp(Alt).
- acquire(Alt) ×2 → 1× keyDown only.
- acquire ×2, release ×1 → no keyUp; second release → keyUp.
- Underflow release → no-op + log.

**`ConfigParserTests`**
- Default JSON → all 14 bindings present.
- Missing field (no `mouseSpeed`) → default + warning.
- `deadzone: -0.1` → clamp to 0.0 + warning.
- `deadzone: 0.8` → clamp to 0.49 + warning.
- `mouseSpeed: 0` → default 15 + warning.
- `bindings.buttonZ` (unknown key) → entry dropped + warning.
- `bindings.buttonA.key: "Foo"` → that binding becomes `.none` + warning.
- Partial bindings (only buttonA) → others fill in as `.none`.

### Manual integration checklist

Run after implementation against the real app + a real controller:

1. Connect Xbox controller; push left stick → cursor moves; release → cursor stops.
2. Push right stick → page scrolls (vertical and horizontal both work).
3. Press A → space character appears in a focused text field.
4. Press RT → Alt+Return fires (in Finder this triggers rename).
5. Hold LT → RightShift held; combined with letter keys produces uppercase.
6. Edit `~/Library/Application Support/FooTinderPad/config.json` (e.g. change `mouseSpeed`); save → new value takes effect without restart.
7. Disconnect Xbox, connect DualSense → DualSense becomes active; reverse order → reverts to Xbox.
8. Connect both at once → most recently connected wins.
9. Revoke Accessibility permission while running → menu bar icon turns red within 5 s; no inputs synthesized; no crash.
10. Crash test: edit config to invalid JSON, save → previous config still active; menu bar warning visible in Console.app.

---

## Open Items Deferred to Implementation Plan

- Exact log subsystem / category names.
- Whether `swift build` settings need any flags for `GameController.framework` import (likely just a Swift import, no Package.swift change).
- App entitlements: `.app` is currently signed with a self-issued cert; verify `AXIsProcessTrusted` works under that and that the binding survives codesign re-runs (the existing Makefile uses a stable cert name, which should preserve the TCC entry).

---

## Decision Log

| Decision | Choice | Why |
|---|---|---|
| Config location | `~/Library/Application Support/FooTinderPad/config.json` + hot reload | Editable from any text editor; instant feedback loop. |
| Multiple controllers | Last-connected wins | Most natural; new controller = intent to use it. No UI required. |
| Accessibility onboarding | Custom NSAlert + jump to Settings | Native prompt unreliable for LSUIElement apps. |
| Key naming | PC-style with macOS aliases | Matches user's existing `Alt+Return` config; aliases keep mac muscle memory working. |
| `Delete` token | Forward Delete | PC convention; user uses `Backspace` for the large key. |
| Trigger thresholds | 0.55 / 0.45 hysteresis, fixed | Avoids chatter; configurability deferred (YAGNI). |
| Mouse Y axis | Inverted from stick | Stick up = cursor up matches user intuition. |
| Scroll Y axis | Not inverted | OS natural-scroll setting handles direction preference. |
| Tick clock | CVDisplayLink, refresh-rate normalized | Smooth motion synced to compositor; ProMotion-safe. |
| Menu bar | Minimal: status + Reload + Reveal + About + Quit | YAGNI; Pause/Logs deferred. |
| Modifier overlap | Ref-counted | Cheap to implement; correctness for shared modifiers (`Alt+Return` + `Alt+Tab`). |
