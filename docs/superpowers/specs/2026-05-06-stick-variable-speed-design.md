# Stick Variable-Speed Response Curve

**Date:** 2026-05-06
**Status:** Design approved, pending implementation plan

## Problem

The left and right thumbsticks already produce a linearly varying speed
(half-deflection ≈ 41 % of full-push speed after deadzone). In practice
that linear curve does not feel "variable" enough: light pushes are still
too fast for fine cursor positioning, and there is no way to tune the
trade-off between precision (low end) and traversal speed (high end).

## Goal

Introduce an exponential response curve so that:

- Light push → markedly slower than today (precision)
- Full push → identical speed to today (traversal unchanged)
- Tunable per role (mouse vs. scroll) via JSON config
- Hot-reloadable, like every other config field

## Non-goals

- Discrete gear/tier modes (rejected: option B in brainstorming)
- Separate min/max speeds (rejected: option C — adds two more fields without
  solving the underlying "linear feels flat" complaint)
- Per-stick (left/right) curve config (rejected: option A3 — couples curve
  to physical stick rather than to its assigned role; inconsistent with
  existing `mouseSpeed` / `scrollSpeed` which are role-keyed)

## Design

### Math

Inside `StickProcessor.tick`, after the existing deadzone-normalised
magnitude `n` is computed, apply a power curve:

```
n         = (mag - deadzone) / (1 - deadzone)   // existing, unchanged
n_curved  = pow(n, curve)                       // new
scale     = n_curved / mag                      // replaces n / mag
```

Properties:

- **Direction preserved.** `x / mag` and `y / mag` are untouched; only the
  magnitude is reshaped.
- **Endpoints fixed.** `n = 0 → 0`, `n = 1 → 1`. Full-push speed equals
  `speed`, identical to the pre-change behaviour.
- **Mid-range compressed.** With `curve = 2.0`: `n = 0.5 → n_curved = 0.25`
  (half-deflection now produces 1/4 speed instead of 1/2).
- `curve < 1.0` is also legal — it expands the mid-range. Uncommon but not
  forbidden; clamp range below allows it.

### Config schema

Two new optional `Double` fields, sibling to `mouseSpeed` / `scrollSpeed`:

```json
{
  "deadzone": 0.15,
  "mouseSpeed": 15,
  "mouseCurve": 2.0,
  "scrollSpeed": 5,
  "scrollCurve": 1.0,
  ...
}
```

`ResolvedConfig` gains:

```swift
let mouseCurve: Double
let scrollCurve: Double
```

### Loader semantics (`ConfigLoader.load`)

| Input                                | Result                                            |
| ------------------------------------ | ------------------------------------------------- |
| field omitted                        | apply default (mouse=2.0, scroll=1.0), no warning |
| value within `[0.5, 4.0]`            | use as-is                                         |
| value outside `[0.5, 4.0]` (incl. ≤0) | clamp into range + emit warning                   |

Warning string mirrors the existing `deadzone` form, e.g.
`mouseCurve 5.0 out of range; clamped to [0.5, 4.0]`.

Negative or zero values are treated as "out of range" rather than "missing"
because the user demonstrably typed a value — falling back to the default
would silently discard their intent.

### Wiring

`StickProcessor.tick` gains a `curve` parameter, passed per-tick (not stored)
so a hot-reload of `mouseCurve` / `scrollCurve` takes effect on the next
tick — same model as `speed`:

```swift
mutating func tick(x: Double, y: Double, speed: Double, curve: Double,
                   tickScale: Double, invertY: Bool) -> StickEmit
```

`InputDispatcher.emit` selects the curve by role, not by physical stick:

```swift
case .mouse:
    processor.tick(x: x, y: y,
                   speed: cfg.mouseSpeed, curve: cfg.mouseCurve,
                   tickScale: tickScale, invertY: true)
case .scroll:
    processor.tick(x: x, y: y,
                   speed: cfg.scrollSpeed, curve: cfg.scrollCurve,
                   tickScale: tickScale, invertY: false)
```

If both sticks are mapped to `mouse`, both will use `mouseCurve`.
That is the intended behaviour and is consistent with how `mouseSpeed`
already works.

### Default-config touch points

All four locations must stay in sync:

1. `Resources/DefaultConfig.json` — bundle resource; written into the
   user's config directory on first run.
2. `Sources/FooTinderPad/Config/DefaultConfig.swift` — embedded fallback
   string used when the bundle resource is unreadable.
3. `Sources/FooTinderPad/Config/Config.swift` — `ResolvedConfig.empty`
   placeholder used during initialisation.
4. `README.md` — the JSON snippet under "預設設定" documents the defaults
   visible to users.

Defaults: `mouseCurve = 2.0`, `scrollCurve = 1.0`.

Rationale for asymmetric defaults: the variable-speed pain point is
cursor precision, not scroll precision. A scroll expo curve would make
slow-scroll near-zero, which rarely matches real intent. Mouse gets the
new feel by default; scroll keeps its current linear behaviour.

## Tests

### `StickProcessorTests.swift` (new cases)

- `curve == 1.0` reproduces the existing baseline output for a representative
  set of inputs (regression guard).
- `curve == 2.0` with mid-range deflection (e.g. `x` chosen so `n = 0.5`
  after deadzone) emits ≈ 1/4 of the full-push delta, not 1/2.
- `curve == 2.0` at full push (`x = 1.0`) emits the same delta as
  `curve == 1.0` at full push — the endpoint-invariance property.
- Pure-axis input `(x = 0.7, y = 0.0)` with `curve == 2.0` keeps `deltaY = 0`
  — direction-preservation property.
- Inputs inside the deadzone still emit `(0, 0)` and reset the accumulator
  regardless of `curve`.

### `ConfigParserTests.swift` (new cases)

- Missing `mouseCurve` / `scrollCurve` → defaults applied (2.0 / 1.0), no
  warnings.
- `mouseCurve: 0.1` (below floor) → clamped to 0.5 with warning matching
  `mouseCurve ... out of range; clamped to [0.5, 4.0]`.
- `mouseCurve: 10.0` (above ceiling) → clamped to 4.0 with warning.
- `mouseCurve: -1.0` → clamped to 0.5 with warning (covers the "≤ 0
  is out-of-range, not missing" decision).
- One boundary case for `scrollCurve` to confirm both fields are wired
  through the loader (full coverage on `mouse`, smoke check on `scroll`).

### Manual verification checklist

Ship-readiness checks performed against a paired controller; not part of
the automated suite.

- Light push of a `mouse`-role stick clearly moves the cursor slower than
  pre-change behaviour.
- Full push of the same stick feels identical to pre-change behaviour.
- Edit user config `mouseCurve: 1.0` while running → cursor returns to
  linear without app restart (hot-reload sanity check).
- Edit user config `mouseCurve: 99` → menu bar shows the clamp warning
  and the cursor behaves as if `mouseCurve: 4.0`.

## Risk

- Existing users who had built muscle memory around the linear curve will
  notice cursor behaviour change after upgrade. This is intentional (the
  feature exists because the linear curve is unsatisfying), and the change
  is one-line revert in their user config (`"mouseCurve": 1.0`). Document
  this in the commit message / release note.
