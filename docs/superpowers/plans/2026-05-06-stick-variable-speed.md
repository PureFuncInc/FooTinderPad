# Stick Variable-Speed Response Curve Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an exponential response curve to thumbstick → mouse / scroll output so light pushes are slower for precision, while full pushes match today's speed.

**Architecture:** Apply `pow(n, curve)` to the deadzone-normalised magnitude inside `StickProcessor.tick`. Curve is supplied per-tick from the resolved config (separate `mouseCurve` and `scrollCurve` fields, role-keyed exactly like `mouseSpeed` / `scrollSpeed`). Default `mouseCurve = 2.0`, `scrollCurve = 1.0`. Out-of-range values are clamped to `[0.5, 4.0]` with a loader warning.

**Tech Stack:** Swift 5.9, XCTest, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-05-06-stick-variable-speed-design.md`

---

## File Map

| Path | Change |
| --- | --- |
| `Sources/FooTinderPad/Config/Config.swift` | Add `mouseCurve` / `scrollCurve` to `ResolvedConfig`, `.empty`, `RawConfig`, and loader logic. |
| `Sources/FooTinderPad/Input/StickProcessor.swift` | Add `curve` parameter to `tick`; apply `pow` to `n`. |
| `Sources/FooTinderPad/Input/InputDispatcher.swift` | Pass `cfg.mouseCurve` / `cfg.scrollCurve` into `tick`. |
| `Resources/DefaultConfig.json` | Add `mouseCurve: 2.0`, `scrollCurve: 1.0`. |
| `Sources/FooTinderPad/Config/DefaultConfig.swift` | Mirror the same two fields in the embedded fallback string. |
| `README.md` | Update the documented default-config JSON snippet. |
| `Tests/FooTinderPadTests/StickProcessorTests.swift` | Add curve cases; backfill `curve: 1.0` on existing calls. |
| `Tests/FooTinderPadTests/ConfigParserTests.swift` | Add cases for default / clamp / boundary handling. |

---

## Task 1: Extend `ResolvedConfig` with curve fields

**Files:**
- Modify: `Sources/FooTinderPad/Config/Config.swift`

This is a type-shape change; everything later depends on it. We add the
fields with no parsing logic yet — the loader keeps using literal defaults
so the project still compiles and existing tests keep passing.

- [ ] **Step 1: Add the two new stored properties to `ResolvedConfig`**

In `Sources/FooTinderPad/Config/Config.swift`, edit the `ResolvedConfig`
struct (currently lines 6–25). Insert `mouseCurve` and `scrollCurve` next
to their `*Speed` counterparts:

```swift
struct ResolvedConfig: Equatable {
    let deadzone: Double
    let mouseSpeed: Double
    let mouseCurve: Double
    let scrollSpeed: Double
    let scrollCurve: Double
    let leftStick: StickRole
    let rightStick: StickRole
    let bindings: [ControllerButton: ResolvedBinding]

    static let empty = ResolvedConfig(
        deadzone: 0.15,
        mouseSpeed: 15,
        mouseCurve: 2.0,
        scrollSpeed: 5,
        scrollCurve: 1.0,
        leftStick: .mouse,
        rightStick: .scroll,
        bindings: Dictionary(uniqueKeysWithValues: ControllerButton.allCases.map { ($0, ResolvedBinding.none) })
    )
}
```

- [ ] **Step 2: Initialise the new fields in `ConfigLoader.load`**

Still in `Config.swift`, find the `let cfg = ResolvedConfig(...)`
construction at the end of `ConfigLoader.load` (currently around lines
121–128). Add the two fields with hard-coded defaults so the build stays
green:

```swift
let cfg = ResolvedConfig(
    deadzone: deadzone,
    mouseSpeed: mouseSpeed,
    mouseCurve: 2.0,
    scrollSpeed: scrollSpeed,
    scrollCurve: 1.0,
    leftStick: leftStick,
    rightStick: rightStick,
    bindings: resolved
)
```

The real parsing logic arrives in Task 2.

- [ ] **Step 3: Build and run the existing test suite**

Run: `swift test`
Expected: PASS — every existing test still works because the new fields
have safe defaults and nothing reads them yet.

- [ ] **Step 4: Commit**

```bash
git add Sources/FooTinderPad/Config/Config.swift
git commit -m "refactor(config): add mouseCurve/scrollCurve fields to ResolvedConfig"
```

---

## Task 2: Parse `mouseCurve` / `scrollCurve` from JSON (TDD)

**Files:**
- Modify: `Sources/FooTinderPad/Config/Config.swift`
- Test: `Tests/FooTinderPadTests/ConfigParserTests.swift`

Tests first. They will all fail because the loader still hard-codes the
defaults. Then implement parsing + clamping.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FooTinderPadTests/ConfigParserTests.swift` (inside the
final `}` of `ConfigParserTests`):

```swift
func testMissingCurveFieldsUseDefaults() throws {
    let json = "{}".data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.mouseCurve, 2.0)
    XCTAssertEqual(result.config.scrollCurve, 1.0)
    XCTAssertFalse(result.warnings.contains { $0.contains("Curve") })
}

func testMouseCurveBelowFloorIsClampedWithWarning() throws {
    let json = #"{"mouseCurve": 0.1}"#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.mouseCurve, 0.5)
    XCTAssertTrue(result.warnings.contains {
        $0.contains("mouseCurve") && $0.contains("clamped to [0.5, 4.0]")
    })
}

func testMouseCurveAboveCeilingIsClampedWithWarning() throws {
    let json = #"{"mouseCurve": 10.0}"#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.mouseCurve, 4.0)
    XCTAssertTrue(result.warnings.contains {
        $0.contains("mouseCurve") && $0.contains("clamped to [0.5, 4.0]")
    })
}

func testNegativeMouseCurveIsClampedWithWarning() throws {
    let json = #"{"mouseCurve": -1.0}"#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.mouseCurve, 0.5)
    XCTAssertTrue(result.warnings.contains { $0.contains("mouseCurve") })
}

func testScrollCurveOutOfRangeIsClampedWithWarning() throws {
    let json = #"{"scrollCurve": 5.0}"#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.scrollCurve, 4.0)
    XCTAssertTrue(result.warnings.contains {
        $0.contains("scrollCurve") && $0.contains("clamped to [0.5, 4.0]")
    })
}

func testCurveValuesInRangeUsedAsIs() throws {
    let json = #"{"mouseCurve": 1.5, "scrollCurve": 2.5}"#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.mouseCurve, 1.5)
    XCTAssertEqual(result.config.scrollCurve, 2.5)
    XCTAssertFalse(result.warnings.contains { $0.contains("Curve") })
}
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run: `swift test --filter ConfigParserTests`
Expected: the six new tests fail. Existing tests still pass.

- [ ] **Step 3: Add fields to `RawConfig`**

In `Sources/FooTinderPad/Config/Config.swift`, edit `RawConfig`
(currently lines 35–42):

```swift
private struct RawConfig: Decodable {
    var deadzone: Double?
    var mouseSpeed: Double?
    var mouseCurve: Double?
    var scrollSpeed: Double?
    var scrollCurve: Double?
    var leftStick: StickRole?
    var rightStick: StickRole?
    var bindings: [String: RawBinding]?
}
```

- [ ] **Step 4: Add a private clamp helper**

In `Config.swift`, just above `enum ConfigLoader { ... }`, add:

```swift
private func resolveCurve(
    raw: Double?,
    fieldName: String,
    defaultValue: Double,
    warnings: inout [String]
) -> Double {
    let lower = 0.5
    let upper = 4.0
    guard let value = raw else { return defaultValue }
    if value < lower || value > upper {
        warnings.append("\(fieldName) \(value) out of range; clamped to [\(lower), \(upper)]")
        return min(max(value, lower), upper)
    }
    return value
}
```

- [ ] **Step 5: Use the helper inside `ConfigLoader.load`**

In `Config.swift`, replace the two hard-coded curve defaults added in
Task 1 with calls to the helper. Insert these lines just after the
existing `scrollSpeed` validation block (after line 78 in the
pre-Task-1 file) and pass them into the `ResolvedConfig` initialiser:

```swift
let mouseCurve = resolveCurve(
    raw: raw.mouseCurve,
    fieldName: "mouseCurve",
    defaultValue: 2.0,
    warnings: &warnings
)
let scrollCurve = resolveCurve(
    raw: raw.scrollCurve,
    fieldName: "scrollCurve",
    defaultValue: 1.0,
    warnings: &warnings
)
```

Then update the `ResolvedConfig(...)` construction:

```swift
let cfg = ResolvedConfig(
    deadzone: deadzone,
    mouseSpeed: mouseSpeed,
    mouseCurve: mouseCurve,
    scrollSpeed: scrollSpeed,
    scrollCurve: scrollCurve,
    leftStick: leftStick,
    rightStick: rightStick,
    bindings: resolved
)
```

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS — all old tests plus the six new parser tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/FooTinderPad/Config/Config.swift Tests/FooTinderPadTests/ConfigParserTests.swift
git commit -m "feat(config): parse mouseCurve and scrollCurve with clamp + warning"
```

---

## Task 3: Apply curve in `StickProcessor.tick` (TDD)

**Files:**
- Modify: `Sources/FooTinderPad/Input/StickProcessor.swift`
- Test: `Tests/FooTinderPadTests/StickProcessorTests.swift`

The `tick` signature gains a required `curve: Double` parameter, so every
existing call site (tests + `InputDispatcher`) must update. We backfill
`curve: 1.0` everywhere first to keep the baseline behaviour, then add new
tests that exercise the curve.

- [ ] **Step 1: Write the new failing tests**

Append to `Tests/FooTinderPadTests/StickProcessorTests.swift` inside the
final `}`:

```swift
// curve == 1.0 must reproduce the existing baseline.
func testCurveOneReproducesLinearBehaviour() {
    var p = StickProcessor(deadzone: 0.15)
    let out = p.tick(x: 1.0, y: 0.0, speed: 15, curve: 1.0,
                     tickScale: 1, invertY: true)
    XCTAssertEqual(out.deltaX, 15)
}

// curve == 2.0 at full push still hits full speed (endpoint invariance).
func testCurveTwoFullPushUnchanged() {
    var p = StickProcessor(deadzone: 0.15)
    let out = p.tick(x: 1.0, y: 0.0, speed: 15, curve: 2.0,
                     tickScale: 1, invertY: true)
    XCTAssertEqual(out.deltaX, 15)
}

// Mid-range deflection with curve=2.0 is squared, not linear.
// Pick x so n = 0.5 after deadzone removal: n = (mag - 0.15) / 0.85 = 0.5
// → mag = 0.575. With curve=2, n_curved = 0.25 → emit ≈ 0.25 * speed.
func testCurveTwoCompressesMidRange() {
    var p = StickProcessor(deadzone: 0.15)
    var total = 0
    // accumulate over many ticks to remove rounding noise
    for _ in 0..<100 {
        let out = p.tick(x: 0.575, y: 0.0, speed: 100, curve: 2.0,
                         tickScale: 1, invertY: true)
        total += out.deltaX
    }
    // 100 ticks * 0.25 * 100 speed = 2500
    XCTAssertEqual(total, 2500)
}

// And with curve=1.0 the same input must give the linear answer (~ 0.5 * 100).
func testCurveOneMidRangeIsLinear() {
    var p = StickProcessor(deadzone: 0.15)
    var total = 0
    for _ in 0..<100 {
        let out = p.tick(x: 0.575, y: 0.0, speed: 100, curve: 1.0,
                         tickScale: 1, invertY: true)
        total += out.deltaX
    }
    // 100 ticks * 0.5 * 100 = 5000
    XCTAssertEqual(total, 5000)
}

// Direction must be preserved: pure-x input never produces y output.
func testCurveDoesNotLeakIntoOtherAxis() {
    var p = StickProcessor(deadzone: 0.15)
    let out = p.tick(x: 0.7, y: 0.0, speed: 15, curve: 2.0,
                     tickScale: 1, invertY: true)
    XCTAssertEqual(out.deltaY, 0)
}

// Inputs inside the deadzone still emit zero regardless of curve.
func testInsideDeadzoneCurveIrrelevant() {
    var p = StickProcessor(deadzone: 0.15)
    let out = p.tick(x: 0.05, y: 0.05, speed: 15, curve: 2.0,
                     tickScale: 1, invertY: true)
    XCTAssertEqual(out.deltaX, 0)
    XCTAssertEqual(out.deltaY, 0)
}
```

- [ ] **Step 2: Run the new tests; expect compile failure**

Run: `swift test --filter StickProcessorTests`
Expected: build error — `tick` does not yet have a `curve:` parameter.

- [ ] **Step 3: Update `StickProcessor.tick` signature and math**

Replace `Sources/FooTinderPad/Input/StickProcessor.swift` body of `tick`
(currently lines 18–38) with:

```swift
mutating func tick(x: Double, y: Double, speed: Double, curve: Double,
                   tickScale: Double, invertY: Bool) -> StickEmit {
    let mag = (x * x + y * y).squareRoot()
    guard mag >= deadzone, mag > 0 else {
        accumX = 0; accumY = 0
        return StickEmit(deltaX: 0, deltaY: 0)
    }
    let n = (mag - deadzone) / (1 - deadzone)
    let nCurved = pow(n, curve)
    let scale = nCurved / mag
    let nx = x * scale
    let ny = y * scale

    accumX += nx * speed * tickScale
    accumY += (invertY ? -1 : 1) * ny * speed * tickScale

    let emitX = Int(accumX.rounded(.towardZero))
    let emitY = Int(accumY.rounded(.towardZero))
    accumX -= Double(emitX)
    accumY -= Double(emitY)

    return StickEmit(deltaX: emitX, deltaY: emitY)
}
```

`pow(_:_:)` is provided by `Foundation` (already imported at the top of
the file). No new imports needed.

- [ ] **Step 4: Backfill `curve: 1.0` in every existing test call site**

Edit `Tests/FooTinderPadTests/StickProcessorTests.swift`. In the
seven existing test methods (lines 6–59 of the original file), every call
to `p.tick(...)` must add `curve: 1.0`. Example for the first test:

```swift
let out = p.tick(x: 0.1, y: 0.1, speed: 15, curve: 1.0,
                 tickScale: 1, invertY: true)
```

Apply the same change to every other `tick(...)` call in the existing
tests. (Argument order: `x, y, speed, curve, tickScale, invertY`.)

- [ ] **Step 5: Update `InputDispatcher` to compile**

In `Sources/FooTinderPad/Input/InputDispatcher.swift`, the two
`processor.tick(...)` calls inside `emit(...)` (lines 71–77 of the
original file) must be updated. For now, hard-code `curve: 1.0`; Task 4
swaps that for the real config value. This keeps the project compiling
between tasks.

```swift
case .mouse:
    let out = processor.tick(x: x, y: y, speed: speedMouse,
                             curve: 1.0,
                             tickScale: tickScale, invertY: true)
    mouse.move(deltaX: out.deltaX, deltaY: out.deltaY)
case .scroll:
    let out = processor.tick(x: x, y: y, speed: speedScroll,
                             curve: 1.0,
                             tickScale: tickScale, invertY: false)
    mouse.scroll(deltaX: out.deltaX, deltaY: out.deltaY)
```

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS — original Stick tests still pass with `curve: 1.0`, and
the six new curve tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/FooTinderPad/Input/StickProcessor.swift \
        Sources/FooTinderPad/Input/InputDispatcher.swift \
        Tests/FooTinderPadTests/StickProcessorTests.swift
git commit -m "feat(stick): apply pow(n, curve) response curve in StickProcessor.tick"
```

---

## Task 4: Wire config curves into `InputDispatcher`

**Files:**
- Modify: `Sources/FooTinderPad/Input/InputDispatcher.swift`

Replace the placeholder `curve: 1.0` introduced in Task 3 with the real
per-role values from the config. There is no new behaviour test here —
the StickProcessor tests already cover the math, and ConfigParser tests
cover loader handling. This step is plumbing.

- [ ] **Step 1: Read curves alongside speeds in `tick(dt:)`**

In `Sources/FooTinderPad/Input/InputDispatcher.swift`, edit the
`tick(dt:)` method (currently lines 58–65) so the `emit(...)` call
forwards the curves. Update the helper's signature too.

```swift
func tick(dt: Double) {
    let cfg = configProvider()
    leftStick.deadzone = cfg.deadzone
    rightStick.deadzone = cfg.deadzone
    let scale = dt * 60
    emit(role: cfg.leftStick,
         x: lastLeftX, y: lastLeftY,
         speedMouse: cfg.mouseSpeed, curveMouse: cfg.mouseCurve,
         speedScroll: cfg.scrollSpeed, curveScroll: cfg.scrollCurve,
         processor: &leftStick, tickScale: scale)
    emit(role: cfg.rightStick,
         x: lastRightX, y: lastRightY,
         speedMouse: cfg.mouseSpeed, curveMouse: cfg.mouseCurve,
         speedScroll: cfg.scrollSpeed, curveScroll: cfg.scrollCurve,
         processor: &rightStick, tickScale: scale)
}
```

- [ ] **Step 2: Update `emit(...)` to accept and forward the curves**

Replace the `emit` helper (currently lines 67–78) with:

```swift
private func emit(role: StickRole, x: Double, y: Double,
                  speedMouse: Double, curveMouse: Double,
                  speedScroll: Double, curveScroll: Double,
                  processor: inout StickProcessor, tickScale: Double) {
    switch role {
    case .none:
        return
    case .mouse:
        let out = processor.tick(x: x, y: y, speed: speedMouse,
                                 curve: curveMouse,
                                 tickScale: tickScale, invertY: true)
        mouse.move(deltaX: out.deltaX, deltaY: out.deltaY)
    case .scroll:
        let out = processor.tick(x: x, y: y, speed: speedScroll,
                                 curve: curveScroll,
                                 tickScale: tickScale, invertY: false)
        mouse.scroll(deltaX: out.deltaX, deltaY: out.deltaY)
    }
}
```

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS — no test changes, but the wiring must still compile and
pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/FooTinderPad/Input/InputDispatcher.swift
git commit -m "feat(input): forward mouseCurve/scrollCurve from config into StickProcessor"
```

---

## Task 5: Update bundled and embedded default configs

**Files:**
- Modify: `Resources/DefaultConfig.json`
- Modify: `Sources/FooTinderPad/Config/DefaultConfig.swift`

The four authoritative copies of the defaults must agree:
1. `ResolvedConfig.empty` (already done in Task 1)
2. `ConfigLoader` defaults (already done in Task 2)
3. `Resources/DefaultConfig.json` (this task)
4. `Sources/FooTinderPad/Config/DefaultConfig.swift` (this task)

- [ ] **Step 1: Edit `Resources/DefaultConfig.json`**

Add `mouseCurve` after `mouseSpeed` and `scrollCurve` after `scrollSpeed`.
The full file becomes:

```json
{
  "deadzone": 0.15,
  "mouseSpeed": 15,
  "mouseCurve": 2.0,
  "scrollSpeed": 5,
  "scrollCurve": 1.0,
  "bindings": {
    "buttonA": { "type": "key", "key": "Space" },
    "buttonB": { "type": "key", "key": "Return" },
    "buttonX": { "type": "mouseButton", "button": "left" },
    "buttonY": { "type": "key", "key": "Delete" },
    "leftShoulder": { "type": "key", "key": "Escape" },
    "rightShoulder": { "type": "mouseButton", "button": "right" },
    "leftTrigger": { "type": "key", "key": "RightShift" },
    "rightTrigger": { "type": "key", "key": "Alt+Return" },
    "leftThumbstickButton": { "type": "none" },
    "rightThumbstickButton": { "type": "none" },
    "dpadUp": { "type": "key", "key": "Up" },
    "dpadDown": { "type": "key", "key": "Down" },
    "dpadLeft": { "type": "key", "key": "Left" },
    "dpadRight": { "type": "key", "key": "Right" }
  },
  "leftStick": "mouse",
  "rightStick": "scroll"
}
```

- [ ] **Step 2: Edit `Sources/FooTinderPad/Config/DefaultConfig.swift`**

Mirror the same two new fields in the `json` constant. The relevant
section becomes:

```swift
static let json: String = #"""
{
  "deadzone": 0.15,
  "mouseSpeed": 15,
  "mouseCurve": 2.0,
  "scrollSpeed": 5,
  "scrollCurve": 1.0,
  "leftStick": "mouse",
  "rightStick": "scroll",
  "bindings": {
    "buttonA": { "type": "key", "key": "Space" },
    "buttonB": { "type": "key", "key": "Return" },
    "buttonX": { "type": "mouseButton", "button": "left" },
    "buttonY": { "type": "key", "key": "Delete" },
    "leftShoulder": { "type": "key", "key": "Escape" },
    "rightShoulder": { "type": "mouseButton", "button": "right" },
    "leftTrigger": { "type": "key", "key": "RightShift" },
    "rightTrigger": { "type": "key", "key": "Alt+Return" },
    "leftThumbstickButton": { "type": "none" },
    "rightThumbstickButton": { "type": "none" },
    "dpadUp": { "type": "key", "key": "Up" },
    "dpadDown": { "type": "key", "key": "Down" },
    "dpadLeft": { "type": "key", "key": "Left" },
    "dpadRight": { "type": "key", "key": "Right" }
  }
}
"""#
```

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: PASS — `testParsesDefaultConfigCompletely` exercises the
default-config-shaped JSON, so a malformed default would fail it.

- [ ] **Step 4: Commit**

```bash
git add Resources/DefaultConfig.json Sources/FooTinderPad/Config/DefaultConfig.swift
git commit -m "feat(config): seed default mouseCurve=2.0 and scrollCurve=1.0"
```

---

## Task 6: Update README defaults snippet

**Files:**
- Modify: `README.md`

The README documents the default config under "預設設定". It must mirror
the JSON we just shipped, otherwise the docs lie about defaults.

- [ ] **Step 1: Edit the JSON snippet in `README.md`**

Replace the snippet (currently lines 7–31). Insert `mouseCurve` after
`mouseSpeed` and `scrollCurve` after `scrollSpeed`:

```json
{
  "deadzone": 0.15,
  "mouseSpeed": 15,
  "mouseCurve": 2.0,
  "scrollSpeed": 5,
  "scrollCurve": 1.0,
  "bindings": {
    "buttonA": { "type": "key", "key": "Space" },
    "buttonB": { "type": "key", "key": "Return" },
    "buttonX": { "type": "mouseButton", "button": "left" },
    "buttonY": { "type": "key", "key": "Delete" },
    "leftShoulder": { "type": "key", "key": "Escape" },
    "rightShoulder": { "type": "mouseButton", "button": "right" },
    "leftTrigger": { "type": "key", "key": "RightShift" },
    "rightTrigger": { "type": "key", "key": "Alt+Return" },
    "leftThumbstickButton": { "type": "none" },
    "rightThumbstickButton": { "type": "none" },
    "dpadUp": { "type": "key", "key": "Up" },
    "dpadDown": { "type": "key", "key": "Down" },
    "dpadLeft": { "type": "key", "key": "Left" },
    "dpadRight": { "type": "key", "key": "Right" }
  },
  "leftStick": "mouse",
  "rightStick": "scroll"
}
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document default mouseCurve and scrollCurve in README"
```

---

## Task 7: Final verification

**Files:** none modified.

- [ ] **Step 1: Run the entire test suite one more time**

Run: `swift test`
Expected: PASS, all green.

- [ ] **Step 2: Build the release binary**

Run: `make build`
Expected: clean compile, no warnings about the new symbols.

- [ ] **Step 3: Manual smoke (controller required)**

Build and run via `make run`. With a paired controller:

- Light push the mouse-role stick — cursor should move clearly slower than
  before this branch.
- Full push the same stick — speed should feel identical to before.
- Edit the user's config file (`~/Library/Application Support/FooTinderPad/config.json`,
  or wherever `Paths.configURL` points), set `"mouseCurve": 1.0`, save —
  cursor should immediately revert to linear behaviour without restart
  (hot-reload sanity).
- Set `"mouseCurve": 99` — menu bar warning surface should show the
  clamp message; cursor should behave as if `mouseCurve: 4.0`.

- [ ] **Step 4: Tag the work as done**

If steps 1–3 pass, the feature is complete. No final commit is required;
the per-task commits already form the merge-ready history.

---

## Notes for the implementer

- The existing project already imports `Foundation` in
  `StickProcessor.swift`, so `pow` is available; no extra import needed.
- The four default-config touch-points listed in Task 5 must stay in
  sync. If you change the schema again later, search for `mouseSpeed` to
  find every copy.
- Existing user config files in `~/Library/Application Support/FooTinderPad`
  will not have the new fields; the loader's "missing → default" path
  handles that without warnings.
- Docs/spec for context: `docs/superpowers/specs/2026-05-06-stick-variable-speed-design.md`.
