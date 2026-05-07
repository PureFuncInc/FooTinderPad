# Touchpad Surface Input

**Date:** 2026-05-07
**Status:** Design approved, pending implementation plan

## Problem

The PS4 / PS5 controller touchpad surface is currently unused. Only the
physical click of the entire pad is wired (as `touchpadButton`). The
analog X/Y reported by `GCControllerTouchpad.touchpadOne.touchSurface`
is dropped on the floor.

A user who has already assigned both thumbsticks (e.g. left = mouse,
right = scroll) and wants to free up a stick for something else has no
alternative input source for mouse/scroll. The touchpad surface is the
natural candidate.

## Goal

Let the touchpad surface drive mouse movement *or* scroll, configurable
via JSON, behaving like a MacBook trackpad — i.e. delta of finger
position, not absolute position-as-velocity.

- Single-finger only (`touchpadOne`).
- Mouse and scroll roles, plus `none` (default).
- Independent speed knobs (`touchpadMouseSpeed`, `touchpadScrollSpeed`).
- Coexists with the existing `touchpadButton` click binding without
  interference.
- Hot-reloadable like every other config field.

## Non-goals

- **Multi-finger gestures** (pinch, two-finger swipe, three-finger).
  Only `touchpadOne` is read; `touchpadTwo` is ignored. Reason: avoids
  a separate gesture-recognition layer; v2 territory.
- **Absolute position mapping** (finger position = cursor position).
  Rejected during brainstorming — feels foreign to a controller.
- **Tap-to-click.** Click remains exclusively `touchpadButton` (the
  whole-pad press). Reason: avoids a debounce/timing layer.
- **Touchpad-as-bindings** (analogous to `dpad: "bindings"`). The
  touchpad reports continuous X/Y, not discrete buttons; the binding
  model does not apply.
- **Deadzone / curve / Y-invert tuning fields.** Shipped values are
  hardcoded based on implementation-time tuning; only revisit if real
  use exposes a need.
- **Stick-like velocity mode.** Considered and rejected during
  brainstorming: holding finger at the edge would cause infinite drift,
  unlike a physical thumbstick that springs to center.
- **Xbox / generic controller fallback.** No touchpad surface exists on
  these hardware classes; wiring is silently skipped.

## Design

### Behaviour and data flow

```
ControllerManager.wire(_:)
    pad as? GCDualSenseGamepad / GCDualShockGamepad
    pad.touchpadOne.valueChangedHandler
        → dispatcher.handleTouchpad(x:, y:, touched:)
            sets lastTouchpadX / lastTouchpadY / touchpadActive

InputDispatcher.tick(dt:)
    touchpadProcessor.tick(currentX, currentY, touched, speed, tickScale)
        - was touched, still touched: emit (current - last) × speed × tickScale
        - just touched (begin):       set last = current; emit (0, 0)
        - just released (end):        clear last; emit (0, 0)
        - never touched:              emit (0, 0)
    → mouse.move(...) for role .mouse   (invertY: true)
    → mouse.scroll(...) for role .scroll (invertY: false)
    → no-op for role .none
```

**Why tick-based, not event-based.** Sticks already cache `lastLeftX/Y`
and emit on tick. Touchpad uses the same shape so emission timing
remains uniform and hot-reloaded `speed` values take effect on the next
tick without special handling. The framework can fire
`valueChangedHandler` at high rates; coalescing into 60 Hz ticks is
desirable.

**Y-axis convention.** Mirrors the existing stick conventions exactly,
so the touchpad feels consistent with `leftStick: "mouse"` /
`rightStick: "scroll"`:
- `mouse`: `invertY: true`  (matches stick mouse — finger up → cursor up)
- `scroll`: `invertY: false` (matches stick scroll)

**Touch begin/end detection.** Apple's `GCControllerTouchpad` exposes
both `touchSurface` (X/Y) and `touchSurfaceButton` (a per-touch
"finger present" signal, distinct from the gamepad-level
`touchpadButton` click). The implementation should prefer
`touchSurfaceButton.isPressed` if reliable; otherwise fall back to a
zero-zero heuristic on the X/Y axes (treat `x == 0 && y == 0` as
released). The `TouchpadProcessor` accepts a `touched: Bool` parameter
and is agnostic to detection strategy — switching strategies later is
local to `InputDispatcher.handleTouchpad`.

### Config schema

Three new optional fields on `RawConfig` / `ResolvedConfig`:

```json
{
  "touchpad": "scroll",
  "touchpadMouseSpeed": 300,
  "touchpadScrollSpeed": 20
}
```

| Field                 | Type           | Default  | Validation                                        |
|-----------------------|----------------|----------|---------------------------------------------------|
| `touchpad`            | `TouchpadRole` | `.none`  | unknown string → warning + `.none`                |
| `touchpadMouseSpeed`  | `Double`       | `300`    | `<= 0` → warning + default                        |
| `touchpadScrollSpeed` | `Double`       | `20`     | `<= 0` → warning + default                        |

```swift
enum TouchpadRole: String, Codable {
    case mouse, scroll, none
}
```

`TouchpadRole` is a new enum, deliberately not aliased to `StickRole`
even though current cases match. Keeps room for touchpad-only values
later without leaking into stick semantics.

**Default rationale.** PS5 touchpad ≈ 52 mm wide; full-width swipe
spans 2.0 in normalised X. With `touchpadMouseSpeed = 300`, a
full-width swipe yields ~600 px (about half a 1440-wide screen) — a
sensible first cut, retunable during implementation.

### File changes

**New (2):**

| File                                                          | Purpose                                                       |
|---------------------------------------------------------------|---------------------------------------------------------------|
| `Sources/FooTinderPad/Input/TouchpadProcessor.swift`          | `struct TouchpadProcessor`; reuses `StickEmit`                |
| `Tests/FooTinderPadTests/TouchpadProcessorTests.swift`        | Unit tests (see Testing)                                      |

**Modified (5):**

| File                                                          | Change                                                        |
|---------------------------------------------------------------|---------------------------------------------------------------|
| `Sources/FooTinderPad/Foundation/Types.swift`                 | Add `enum TouchpadRole`                                       |
| `Sources/FooTinderPad/Config/Config.swift`                    | New fields on `RawConfig` / `ResolvedConfig`; `ConfigLoader.load` validation; `.empty` updated |
| `Sources/FooTinderPad/Config/DefaultConfig.swift`             | New defaults                                                  |
| `Sources/FooTinderPad/Controller/ControllerManager.swift`     | Wire `pad.touchpadOne.valueChangedHandler` for DualSense / DualShock; unwire on disconnect |
| `Sources/FooTinderPad/Input/InputDispatcher.swift`            | New state (`lastTouchpadX/Y`, `touchpadActive`, `touchpadProcessor`); new method `handleTouchpad(x:, y:, touched:)`; new emission step in `tick(dt:)`; `drainHeldInputs()` resets state |
| `Resources/DefaultConfig.json`                                | Add example values for the three new fields                   |

`InputDispatcher` adds a small dedicated emit helper
(`emitTouchpad(role:x:y:touched:speedMouse:speedScroll:processor:tickScale:)`)
rather than generalising the existing `emit(...)` to two processor
types. ~15 lines, no new abstraction layer.

### TouchpadProcessor

```swift
struct TouchpadProcessor {
    private var lastX: Double?
    private var lastY: Double?
    private var accumX: Double = 0
    private var accumY: Double = 0

    mutating func tick(x: Double, y: Double, touched: Bool,
                       speed: Double, tickScale: Double,
                       invertY: Bool) -> StickEmit {
        guard touched else {
            lastX = nil; lastY = nil
            accumX = 0; accumY = 0
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        guard let lx = lastX, let ly = lastY else {
            lastX = x; lastY = y
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        let dx = x - lx
        let dy = y - ly
        lastX = x; lastY = y

        accumX += dx * speed * tickScale
        accumY += (invertY ? -1 : 1) * dy * speed * tickScale

        let emitX = Int(accumX.rounded(.towardZero))
        let emitY = Int(accumY.rounded(.towardZero))
        accumX -= Double(emitX)
        accumY -= Double(emitY)

        return StickEmit(deltaX: emitX, deltaY: emitY)
    }

    mutating func drain() {
        lastX = nil; lastY = nil
        accumX = 0; accumY = 0
    }
}
```

Properties:
- **No drift on hold.** Finger held still → `dx = dy = 0` → no emit.
- **No jump on touch begin.** First-touch tick records `last` and
  emits zero.
- **No jump on touch resume.** Lifting and re-landing resets `last`,
  so the new landing position is not treated as a giant delta from
  wherever the finger last was.
- **Sub-pixel accumulation.** Fractional deltas accrue across ticks
  rather than being lost — same trick as `StickProcessor`.

### Coexistence with `touchpadButton` (click)

Click and surface are independent inputs from the framework, on
independent dispatcher methods, with independent state.

- Finger resting on surface but not clicking → `touched = true`,
  `delta = 0` → no events. Click binding inactive. ✅
- Finger sliding while pressing → surface emits delta; click fires
  the `touchpadButton` binding. Both run. ✅
- Quick tap-and-lift → touch begin records `last`; touch end clears
  it; no surface emission. Click binding fires for the press. ✅

No "click pauses surface" coupling — would introduce cross-input
state dependency without a real win. Users who want surface disabled
set `touchpad: "none"`.

### Hot-reload

`ConfigLoader.load` rebuilds the full `ResolvedConfig`; the
dispatcher's `configProvider()` callback returns the latest on every
tick. Switching `touchpad` from `mouse` to `scroll` mid-swipe simply
changes which output sink the next tick's delta routes to. Speed
changes apply on the next tick. No state reset needed; `lastX/Y`
remains valid for delta computation regardless of role.

## Testing

### `TouchpadProcessorTests.swift` (~8 cases)

- Untouched ticks emit zero.
- First-touch tick records `last` and emits zero.
- Sustained touch with motion emits delta scaled by `speed × tickScale`.
- Lift-then-relanding resets `last` (no spurious jump).
- `invertY: true` flips Y; `invertY: false` does not.
- Sub-pixel deltas accumulate across ticks into integer emits.
- Mid-stream `speed` change applies on the next tick.
- `drain()` clears `last` and accumulator.

### `InputDispatcherTests.swift` (additions, ~4 cases)

- `touchpad: .none` + handleTouchpad sequence + tick → mouse sink empty.
- `touchpad: .scroll` + sliding sequence → `mouse.scroll` invoked with
  expected sign on X and Y (no Y inversion for scroll).
- `touchpad: .mouse` + sliding sequence → `mouse.move` invoked with
  Y inverted.
- `drainHeldInputs()` resets touchpad state — subsequent ticks emit
  zero until a new touch begin.

### `ConfigParserTests.swift` (additions, ~4 cases)

- Empty JSON → defaults (`.none`, 300, 20).
- `"touchpad": "scroll"` parses to `.scroll`.
- `touchpadMouseSpeed: 0` → warning + default.
- `"touchpad": "wat"` → unknown string → warning + `.none`.

### Not unit-tested

- `ControllerManager` wiring of `GCDualSenseGamepad.touchpadOne` —
  consistent with existing controller-layer code which is verified
  manually due to GameController framework dependency.
- Real-device feel — covered by a manual smoke checklist in the
  implementation plan.
