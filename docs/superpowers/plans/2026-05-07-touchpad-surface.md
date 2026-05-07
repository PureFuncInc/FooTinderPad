# Touchpad Surface Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the PS4/PS5 controller touchpad surface drive mouse movement or scroll in delta (trackpad-like) mode, configurable via JSON, single-finger only, coexisting with the existing `touchpadButton` click binding.

**Architecture:** Mirror the existing stick pipeline: `ControllerManager` wires `pad.touchpadOne.valueChangedHandler` (DualSense / DualShock only); the dispatcher caches the latest `(x, y, touched)` and a new `TouchpadProcessor` emits per-tick deltas which feed the same `MouseSynthesizer.move` / `MouseSynthesizer.scroll` outputs already used by the sticks. New `TouchpadRole` enum (`mouse | scroll | none`, default `none`); new config fields `touchpadMouseSpeed` (default 300), `touchpadScrollSpeed` (default 20).

**Tech Stack:** Swift 5.9, Apple GameController framework, XCTest, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-05-07-touchpad-surface-design.md`

---

## File Map

| Path | Change |
| --- | --- |
| `Sources/FooTinderPad/Foundation/Types.swift` | Add `enum TouchpadRole`. |
| `Sources/FooTinderPad/Config/Config.swift` | Add `touchpad`, `touchpadMouseSpeed`, `touchpadScrollSpeed` fields to `ResolvedConfig` / `.empty` / `RawConfig`; speed validation; manual parse of role string with warning on unknown value. |
| `Sources/FooTinderPad/Input/TouchpadProcessor.swift` | NEW. `struct TouchpadProcessor` with `tick(x:y:touched:speed:tickScale:invertY:)` and `drain()`. |
| `Sources/FooTinderPad/Input/InputDispatcher.swift` | Add `lastTouchpadX/Y`, `touchpadActive`, `touchpadProcessor`, `handleTouchpad(x:y:touched:)`, `emitTouchpad(...)`, integration in `tick(dt:)` and `drainHeldInputs()`. |
| `Sources/FooTinderPad/Controller/ControllerManager.swift` | New helper `touchpadOne(of:)`; wire `valueChangedHandler` in `wire(_:)`; clear it in `unwireCurrent()`. |
| `Resources/DefaultConfig.json` | Add the three new fields with default values. |
| `Sources/FooTinderPad/Config/DefaultConfig.swift` | Mirror those defaults in the embedded fallback string. |
| `README.md` | Document the touchpad surface role + speed knobs in the existing tables / example block. |
| `Tests/FooTinderPadTests/ConfigParserTests.swift` | New cases for defaults / speed validation / unknown role / valid role. |
| `Tests/FooTinderPadTests/TouchpadProcessorTests.swift` | NEW. ~8 cases covering touch begin / end / motion / drift / drain / invertY / sub-pixel accumulation / mid-stream speed change. |
| `Tests/FooTinderPadTests/InputDispatcherTests.swift` | Update `makeConfig` helper signature; add 4 cases for `.none` / `.mouse` / `.scroll` / drain. |

---

## Task 1: Add `TouchpadRole` enum and extend `ResolvedConfig`

**Files:**
- Modify: `Sources/FooTinderPad/Foundation/Types.swift`
- Modify: `Sources/FooTinderPad/Config/Config.swift`
- Modify: `Tests/FooTinderPadTests/ConfigParserTests.swift`
- Modify: `Tests/FooTinderPadTests/InputDispatcherTests.swift`

This task lays the type-shape foundation. We add the new enum, three new
`ResolvedConfig` fields with default values, mirror them in `RawConfig`,
pass them through `ConfigLoader.load` with no validation yet (just `??`
defaults), and update the test-helper `makeConfig` so the existing
dispatcher tests keep compiling. After this task, all existing tests
must still pass.

- [ ] **Step 1: Add a parser test that asserts the new defaults**

Append to `Tests/FooTinderPadTests/ConfigParserTests.swift` (anywhere
inside the `ConfigParserTests` class — group it after
`testMissingFieldsUseDefaults`):

```swift
    func testTouchpadFieldsHaveDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpad, .none)
        XCTAssertEqual(result.config.touchpadMouseSpeed, 300)
        XCTAssertEqual(result.config.touchpadScrollSpeed, 20)
    }
```

Also extend the existing `testParsesDefaultConfigCompletely` to assert
the same three defaults (the current default JSON does not yet specify
them — that comes in Task 7). Add at the bottom of that test, just
before `XCTAssertTrue(result.warnings.isEmpty)`:

```swift
        XCTAssertEqual(result.config.touchpad, .none)
        XCTAssertEqual(result.config.touchpadMouseSpeed, 300)
        XCTAssertEqual(result.config.touchpadScrollSpeed, 20)
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `swift test --filter ConfigParserTests/testTouchpadFieldsHaveDefaults`

Expected: BUILD FAILURE — `ResolvedConfig` has no member `touchpad`.

- [ ] **Step 3: Add the `TouchpadRole` enum**

In `Sources/FooTinderPad/Foundation/Types.swift`, immediately after the
existing `enum DPadRole` (line 21–23), add:

```swift
enum TouchpadRole: String, Codable {
    case mouse, scroll, none
}
```

- [ ] **Step 4: Add three new properties to `ResolvedConfig`**

In `Sources/FooTinderPad/Config/Config.swift`, inside `struct
ResolvedConfig` (around line 7–14), add these stored properties below
`dpadScrollSpeed`:

```swift
    let touchpad: TouchpadRole
    let touchpadMouseSpeed: Double
    let touchpadScrollSpeed: Double
```

So the property list becomes (in order):

```swift
    let deadzone: Double
    let mouseSpeed: Double
    let scrollSpeed: Double
    let leftStick: StickRole
    let rightStick: StickRole
    let dpad: DPadRole
    let dpadMouseSpeed: Double
    let dpadScrollSpeed: Double
    let touchpad: TouchpadRole
    let touchpadMouseSpeed: Double
    let touchpadScrollSpeed: Double
    let bindings: [ControllerButton: ResolvedBinding]
```

- [ ] **Step 5: Update `ResolvedConfig.empty`**

In the same file (around line 20–30), add the three new initialiser
arguments before `bindings:`:

```swift
    static let empty = ResolvedConfig(
        deadzone: 0.15,
        mouseSpeed: 15,
        scrollSpeed: 5,
        leftStick: .mouse,
        rightStick: .scroll,
        dpad: .bindings,
        dpadMouseSpeed: 3,
        dpadScrollSpeed: 2,
        touchpad: .none,
        touchpadMouseSpeed: 300,
        touchpadScrollSpeed: 20,
        bindings: Dictionary(uniqueKeysWithValues: ControllerButton.allCases.map { ($0, ResolvedBinding.none) })
    )
```

- [ ] **Step 6: Mirror the new fields on `RawConfig`**

In `Sources/FooTinderPad/Config/Config.swift`, inside `private struct
RawConfig: Decodable` (around line 39–48), add:

```swift
    var touchpad: TouchpadRole?
    var touchpadMouseSpeed: Double?
    var touchpadScrollSpeed: Double?
```

> **Note:** `TouchpadRole?` will throw on unknown values during JSON
> decode. Task 3 changes this to a `String?` to honour the spec's
> "warning + `.none`" promise. Keep it simple here.

- [ ] **Step 7: Pass the new fields through `ConfigLoader.load`**

In `Sources/FooTinderPad/Config/Config.swift`, inside `ConfigLoader.load`,
just before the `let leftStick = ...` line (around line 95), add the
default plumbing — **no validation yet, just `??` defaults**:

```swift
        let touchpad = raw.touchpad ?? .none
        let touchpadMouseSpeed = raw.touchpadMouseSpeed ?? 300
        let touchpadScrollSpeed = raw.touchpadScrollSpeed ?? 20
```

Then add the three values to the `ResolvedConfig(...)` initialiser at
the end of `load(...)` (around line 153), inserting them before
`bindings:`:

```swift
        let cfg = ResolvedConfig(
            deadzone: deadzone,
            mouseSpeed: mouseSpeed,
            scrollSpeed: scrollSpeed,
            leftStick: leftStick,
            rightStick: rightStick,
            dpad: dpad,
            dpadMouseSpeed: dpadMouseSpeed,
            dpadScrollSpeed: dpadScrollSpeed,
            touchpad: touchpad,
            touchpadMouseSpeed: touchpadMouseSpeed,
            touchpadScrollSpeed: touchpadScrollSpeed,
            bindings: resolved
        )
```

- [ ] **Step 8: Update `makeConfig` test helper in `InputDispatcherTests`**

In `Tests/FooTinderPadTests/InputDispatcherTests.swift`, find the
`private func makeConfig(...)` helper (around line 83–104). Extend its
signature and the `ResolvedConfig` it returns:

```swift
    private func makeConfig(
        dpad: DPadRole = .bindings,
        dpadMouseSpeed: Double = 3,
        touchpad: TouchpadRole = .none,
        touchpadMouseSpeed: Double = 300,
        touchpadScrollSpeed: Double = 20,
        bindings: [ControllerButton: ResolvedBinding] = [:]
    ) -> ResolvedConfig {
        var resolved = Dictionary(uniqueKeysWithValues: ControllerButton.allCases.map { ($0, ResolvedBinding.none) })
        for (button, binding) in bindings {
            resolved[button] = binding
        }
        return ResolvedConfig(
            deadzone: 0.15,
            mouseSpeed: 15,
            scrollSpeed: 5,
            leftStick: .none,
            rightStick: .none,
            dpad: dpad,
            dpadMouseSpeed: dpadMouseSpeed,
            dpadScrollSpeed: 2,
            touchpad: touchpad,
            touchpadMouseSpeed: touchpadMouseSpeed,
            touchpadScrollSpeed: touchpadScrollSpeed,
            bindings: resolved
        )
    }
```

The `dpad` parameter now has a default of `.bindings` so existing
callers that did `makeConfig(dpad: .mouse, ...)` keep working
unchanged, and new tests can omit `dpad:` when not relevant.

- [ ] **Step 9: Run the whole test suite to verify it builds and passes**

Run: `swift test`

Expected: All existing tests pass, plus the new
`testTouchpadFieldsHaveDefaults` and the augmented
`testParsesDefaultConfigCompletely` pass.

- [ ] **Step 10: Commit**

```bash
git add Sources/FooTinderPad/Foundation/Types.swift \
        Sources/FooTinderPad/Config/Config.swift \
        Tests/FooTinderPadTests/ConfigParserTests.swift \
        Tests/FooTinderPadTests/InputDispatcherTests.swift
git commit -m "$(cat <<'EOF'
feat(config): add TouchpadRole and touchpad config fields

Introduces TouchpadRole enum (mouse/scroll/none) and three new fields
on ResolvedConfig (touchpad, touchpadMouseSpeed=300,
touchpadScrollSpeed=20). Loader passes them through with simple
?? defaults; validation lands in subsequent commits.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Validate `touchpadMouseSpeed` and `touchpadScrollSpeed`

**Files:**
- Modify: `Sources/FooTinderPad/Config/Config.swift`
- Modify: `Tests/FooTinderPadTests/ConfigParserTests.swift`

Add the same `<= 0 → warning + default` pattern that `mouseSpeed`,
`scrollSpeed`, `dpadMouseSpeed`, and `dpadScrollSpeed` already use.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FooTinderPadTests/ConfigParserTests.swift`:

```swift
    func testZeroTouchpadMouseSpeedFallsBackToDefault() throws {
        let json = #"{"touchpadMouseSpeed": 0}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpadMouseSpeed, 300)
        XCTAssertTrue(result.warnings.contains { $0.contains("touchpadMouseSpeed") })
    }

    func testNegativeTouchpadScrollSpeedFallsBackToDefault() throws {
        let json = #"{"touchpadScrollSpeed": -5}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpadScrollSpeed, 20)
        XCTAssertTrue(result.warnings.contains { $0.contains("touchpadScrollSpeed") })
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter ConfigParserTests/testZeroTouchpadMouseSpeedFallsBackToDefault`
Run: `swift test --filter ConfigParserTests/testNegativeTouchpadScrollSpeedFallsBackToDefault`

Expected: Both FAIL — config returns the user-provided invalid value;
warnings array does not contain the field name.

- [ ] **Step 3: Add validation**

In `Sources/FooTinderPad/Config/Config.swift`, replace the lines
introduced in Task 1 Step 7 (the simple `??` plumbing for
`touchpadMouseSpeed` and `touchpadScrollSpeed`) with:

```swift
        var touchpadMouseSpeed = raw.touchpadMouseSpeed ?? 300
        if touchpadMouseSpeed <= 0 {
            warnings.append("touchpadMouseSpeed must be > 0; using default 300")
            touchpadMouseSpeed = 300
        }
        var touchpadScrollSpeed = raw.touchpadScrollSpeed ?? 20
        if touchpadScrollSpeed <= 0 {
            warnings.append("touchpadScrollSpeed must be > 0; using default 20")
            touchpadScrollSpeed = 20
        }
```

The `let touchpad = raw.touchpad ?? .none` line stays unchanged for
now (Task 3 reworks it).

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter ConfigParserTests`

Expected: All `ConfigParserTests` cases pass, including the two new
ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Config/Config.swift \
        Tests/FooTinderPadTests/ConfigParserTests.swift
git commit -m "$(cat <<'EOF'
feat(config): warn + fall back when touchpad speeds are non-positive

Mirrors the existing mouseSpeed / scrollSpeed / dpadMouseSpeed
validation: any <= 0 value emits a loader warning and reverts to the
default.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Parse `touchpad` role gracefully (warn on unknown)

**Files:**
- Modify: `Sources/FooTinderPad/Config/Config.swift`
- Modify: `Tests/FooTinderPadTests/ConfigParserTests.swift`

The spec promises `unknown string → warning + .none`. The current
`var touchpad: TouchpadRole?` decoded as a typed enum would *throw* on
an unknown value, aborting the entire load. We switch the raw field
to `String?` and parse manually — local change to touchpad only,
leaving `StickRole` / `DPadRole` parsing untouched.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FooTinderPadTests/ConfigParserTests.swift`:

```swift
    func testTouchpadRoleParsesValidValue() throws {
        let json = #"{"touchpad": "scroll"}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpad, .scroll)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnknownTouchpadRoleWarnsAndFallsBackToNone() throws {
        let json = #"{"touchpad": "wat"}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpad, .none)
        XCTAssertTrue(result.warnings.contains { $0.contains("touchpad") })
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter ConfigParserTests/testUnknownTouchpadRoleWarnsAndFallsBackToNone`

Expected: FAIL — the JSON decode throws because `"wat"` is not a valid
`TouchpadRole.rawValue`, so `ConfigLoader.load(from:)` propagates the
error and the test fails with `XCTAssertThrowsError`-like semantics.

- [ ] **Step 3: Switch `RawConfig.touchpad` to `String?`**

In `Sources/FooTinderPad/Config/Config.swift`, inside `RawConfig`,
change the field added in Task 1:

```swift
    var touchpad: String?
```

(Other two `Double?` fields stay the same.)

- [ ] **Step 4: Replace the simple `??` for `touchpad` with manual parse**

In `ConfigLoader.load`, replace:

```swift
        let touchpad = raw.touchpad ?? .none
```

with:

```swift
        var touchpad: TouchpadRole = .none
        if let raw = raw.touchpad {
            if let parsed = TouchpadRole(rawValue: raw) {
                touchpad = parsed
            } else {
                warnings.append("unknown touchpad role '\(raw)'; using none")
            }
        }
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter ConfigParserTests`

Expected: All `ConfigParserTests` cases pass, including the two new
ones.

- [ ] **Step 6: Commit**

```bash
git add Sources/FooTinderPad/Config/Config.swift \
        Tests/FooTinderPadTests/ConfigParserTests.swift
git commit -m "$(cat <<'EOF'
feat(config): warn on unknown touchpad role instead of failing decode

Switches RawConfig.touchpad to String? and parses with a fallback to
.none plus a loader warning, so a typo in the touchpad role does not
abort the whole config load.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Implement `TouchpadProcessor`

**Files:**
- Create: `Sources/FooTinderPad/Input/TouchpadProcessor.swift`
- Create: `Tests/FooTinderPadTests/TouchpadProcessorTests.swift`

The processor is the "delta-mode" sibling of `StickProcessor`. It
remembers the last `(x, y)` only while the finger is touching, so it
can emit `(current - last) × speed × tickScale` per tick. Sub-pixel
deltas accumulate the same way `StickProcessor` does. Lifting the
finger clears `last`, so a re-landing finger does not get treated as
a giant jump.

- [ ] **Step 1: Create the test file with the eight cases**

Create `Tests/FooTinderPadTests/TouchpadProcessorTests.swift` with the
following content:

```swift
import XCTest
@testable import FooTinderPad

final class TouchpadProcessorTests: XCTestCase {

    func testUntouchedTicksEmitZero() {
        var p = TouchpadProcessor()
        let a = p.tick(x: 0, y: 0, touched: false, speed: 300, tickScale: 1, invertY: true)
        let b = p.tick(x: 0.5, y: 0.5, touched: false, speed: 300, tickScale: 1, invertY: true)
        XCTAssertEqual(a, StickEmit(deltaX: 0, deltaY: 0))
        XCTAssertEqual(b, StickEmit(deltaX: 0, deltaY: 0))
    }

    func testFirstTouchTickRecordsLastAndEmitsZero() {
        var p = TouchpadProcessor()
        let out = p.tick(x: 0.5, y: 0.3, touched: true, speed: 300, tickScale: 1, invertY: true)
        XCTAssertEqual(out, StickEmit(deltaX: 0, deltaY: 0))
    }

    func testSustainedMotionEmitsDelta() {
        var p = TouchpadProcessor()
        // Touch begin at (0, 0) — emits zero, records last.
        _ = p.tick(x: 0, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        // Finger moves to (0.1, 0). dx=0.1, dy=0. emit = round(0.1 * 300) = 30.
        let out = p.tick(x: 0.1, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        XCTAssertEqual(out.deltaX, 30)
        XCTAssertEqual(out.deltaY, 0)
    }

    func testReleaseClearsLastSoReLandingDoesNotJump() {
        var p = TouchpadProcessor()
        // Touch begin and slide to (0.5, 0).
        _ = p.tick(x: 0, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        _ = p.tick(x: 0.5, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        // Lift the finger.
        _ = p.tick(x: 0, y: 0, touched: false, speed: 300, tickScale: 1, invertY: false)
        // Re-land at (-0.5, 0). Should be treated as a NEW touch begin.
        let out = p.tick(x: -0.5, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        XCTAssertEqual(out, StickEmit(deltaX: 0, deltaY: 0))
    }

    func testInvertYTrueFlipsYDelta() {
        var p = TouchpadProcessor()
        _ = p.tick(x: 0, y: 0, touched: true, speed: 300, tickScale: 1, invertY: true)
        // Finger up by 0.1 in normalised Y. With invertY: true, emit -30.
        let out = p.tick(x: 0, y: 0.1, touched: true, speed: 300, tickScale: 1, invertY: true)
        XCTAssertEqual(out.deltaY, -30)
    }

    func testInvertYFalseLeavesYDeltaUnchanged() {
        var p = TouchpadProcessor()
        _ = p.tick(x: 0, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        let out = p.tick(x: 0, y: 0.1, touched: true, speed: 300, tickScale: 1, invertY: false)
        XCTAssertEqual(out.deltaY, 30)
    }

    func testSubPixelDeltasAccumulateAcrossTicks() {
        var p = TouchpadProcessor()
        // Touch begin records last position; emits zero.
        _ = p.tick(x: 0, y: 0, touched: true, speed: 16, tickScale: 1, invertY: false)
        // Each tick: x advances by 1/32 (exactly representable in Float64).
        // Per-tick contribution to accumulator = (1/32) * 16 = 0.5 px (sub-pixel).
        // After 10 ticks: total motion = 10 * 0.5 = 5 px → emit total = 5.
        var totalX = 0
        for i in 1...10 {
            let out = p.tick(x: Double(i) / 32.0, y: 0, touched: true,
                             speed: 16, tickScale: 1, invertY: false)
            totalX += out.deltaX
        }
        XCTAssertEqual(totalX, 5)
    }

    func testDrainResetsLastAndAccumulator() {
        var p = TouchpadProcessor()
        _ = p.tick(x: 0, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        _ = p.tick(x: 0.5, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        p.drain()
        // After drain, the next "still touching" frame should look like a fresh begin.
        let out = p.tick(x: 0.9, y: 0, touched: true, speed: 300, tickScale: 1, invertY: false)
        XCTAssertEqual(out, StickEmit(deltaX: 0, deltaY: 0))
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail to compile**

Run: `swift test --filter TouchpadProcessorTests`

Expected: BUILD FAILURE — `TouchpadProcessor` does not exist.

- [ ] **Step 3: Create `TouchpadProcessor.swift`**

Create `Sources/FooTinderPad/Input/TouchpadProcessor.swift`:

```swift
import Foundation

/// Delta-mode processor for the PS4/PS5 controller touch surface.
/// Reuses `StickEmit` as the output type since it carries the same shape
/// (integer X / Y delta to feed into mouse.move or mouse.scroll).
struct TouchpadProcessor {

    private var lastX: Double?
    private var lastY: Double?
    private var accumX: Double = 0
    private var accumY: Double = 0

    mutating func tick(x: Double, y: Double, touched: Bool,
                       speed: Double, tickScale: Double,
                       invertY: Bool) -> StickEmit {
        guard touched else {
            lastX = nil
            lastY = nil
            accumX = 0
            accumY = 0
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        guard let lx = lastX, let ly = lastY else {
            lastX = x
            lastY = y
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        let dx = x - lx
        let dy = y - ly
        lastX = x
        lastY = y

        accumX += dx * speed * tickScale
        accumY += (invertY ? -1 : 1) * dy * speed * tickScale

        let emitX = Int(accumX.rounded(.towardZero))
        let emitY = Int(accumY.rounded(.towardZero))
        accumX -= Double(emitX)
        accumY -= Double(emitY)

        return StickEmit(deltaX: emitX, deltaY: emitY)
    }

    mutating func drain() {
        lastX = nil
        lastY = nil
        accumX = 0
        accumY = 0
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter TouchpadProcessorTests`

Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Input/TouchpadProcessor.swift \
        Tests/FooTinderPadTests/TouchpadProcessorTests.swift
git commit -m "$(cat <<'EOF'
feat(input): add TouchpadProcessor for delta-mode finger motion

Trackpad-like input source: emits per-tick deltas while the finger is
touching, resets last-known position on release, and accumulates
sub-pixel motion across ticks.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire `TouchpadProcessor` into `InputDispatcher`

**Files:**
- Modify: `Sources/FooTinderPad/Input/InputDispatcher.swift`
- Modify: `Tests/FooTinderPadTests/InputDispatcherTests.swift`

Add the cached `(x, y, touched)` state, the `handleTouchpad` entry
point that `ControllerManager` will call (Task 6), the `emitTouchpad`
helper that mirrors the existing `emit(...)` for sticks, the
per-tick emission, and the drain hookup.

- [ ] **Step 1: Add the four dispatcher tests**

Append to `Tests/FooTinderPadTests/InputDispatcherTests.swift` inside
the `InputDispatcherTests` class (place them after the existing
`testDrainClearsHeldDPadMovement` and before the private helpers):

```swift
    func testTouchpadNoneEmitsNothing() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .none, touchpadMouseSpeed: 300, touchpadScrollSpeed: 20)
        )

        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        dispatcher.handleTouchpad(x: 0.5, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [])
    }

    func testTouchpadScrollEmitsScrollWithoutYInversion() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .scroll, touchpadScrollSpeed: 20)
        )

        // Touch begin (records last, emits zero).
        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        // Slide finger up by 0.1 normalised. Expected delta Y = 0.1 * 20 = 2 (no inversion for scroll).
        dispatcher.handleTouchpad(x: 0, y: 0.1, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [
            .scroll(0, 2),
        ])
    }

    func testTouchpadMouseEmitsMoveWithYInversion() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .mouse, touchpadMouseSpeed: 300)
        )

        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        // Finger up 0.1: with invertY true, delta Y = -30.
        dispatcher.handleTouchpad(x: 0, y: 0.1, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [
            .mouseMove(0, -30),
        ])
    }

    func testDrainClearsHeldTouchpadMotion() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .mouse, touchpadMouseSpeed: 300)
        )

        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        dispatcher.drainHeldInputs()
        // Even though we still report touched=true at a new position, the
        // processor was reset so the next tick is a fresh "begin".
        dispatcher.handleTouchpad(x: 0.5, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [])
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter InputDispatcherTests/testTouchpadNoneEmitsNothing`

Expected: BUILD FAILURE — `InputDispatcher` has no `handleTouchpad`
method.

- [ ] **Step 3: Add touchpad state and `handleTouchpad` to the dispatcher**

In `Sources/FooTinderPad/Input/InputDispatcher.swift`, add these stored
properties next to the existing `lastLeftX/Y` / `lastRightX/Y` block
(around line 40–43):

```swift
    private var lastTouchpadX: Double = 0
    private var lastTouchpadY: Double = 0
    private var touchpadActive: Bool = false
    private var touchpadProcessor = TouchpadProcessor()
```

And add the new public method next to `updateLeftStick` /
`updateRightStick` (around line 81–82):

```swift
    func handleTouchpad(x: Double, y: Double, touched: Bool) {
        lastTouchpadX = x
        lastTouchpadY = y
        touchpadActive = touched
    }
```

- [ ] **Step 4: Add a `TouchpadRole → invertY` extension and `emitTouchpad`**

In the same file, immediately after the existing private extension on
`DPadRole` (around line 13–21), add:

```swift
private extension TouchpadRole {
    var invertY: Bool {
        switch self {
        case .mouse: return true
        case .scroll: return false
        case .none: return false
        }
    }
}
```

And add a new private helper inside `InputDispatcher` next to
`emit(...)` (around line 109–128):

```swift
    private func emitTouchpad(role: TouchpadRole, x: Double, y: Double, touched: Bool,
                              speedMouse: Double, speedScroll: Double,
                              processor: inout TouchpadProcessor, tickScale: Double) {
        switch role {
        case .none:
            return
        case .mouse:
            let out = processor.tick(x: x, y: y, touched: touched,
                                     speed: speedMouse,
                                     tickScale: tickScale, invertY: role.invertY)
            mouse.move(deltaX: out.deltaX, deltaY: out.deltaY)
        case .scroll:
            let out = processor.tick(x: x, y: y, touched: touched,
                                     speed: speedScroll,
                                     tickScale: tickScale, invertY: role.invertY)
            mouse.scroll(deltaX: out.deltaX, deltaY: out.deltaY)
        }
    }
```

- [ ] **Step 5: Hook `emitTouchpad` into `tick(dt:)`**

In the same file, inside `func tick(dt: Double)` (around line 86–107),
add the touchpad emission as the **last** step (after the dpad emit):

```swift
        emitTouchpad(role: cfg.touchpad,
                     x: lastTouchpadX, y: lastTouchpadY, touched: touchpadActive,
                     speedMouse: cfg.touchpadMouseSpeed,
                     speedScroll: cfg.touchpadScrollSpeed,
                     processor: &touchpadProcessor, tickScale: scale)
```

- [ ] **Step 6: Reset touchpad state in `drainHeldInputs`**

In the same file, find `func drainHeldInputs()` (around line 130–135)
and update it:

```swift
    func drainHeldInputs() {
        repeater.clear()
        dpadPressed.removeAll()
        touchpadActive = false
        lastTouchpadX = 0
        lastTouchpadY = 0
        touchpadProcessor.drain()
        key.drain()
        mouse.drain()
    }
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `swift test --filter InputDispatcherTests`

Expected: All `InputDispatcherTests` cases pass — the four new ones
plus the four existing D-pad cases.

- [ ] **Step 8: Run the full test suite to confirm no regressions**

Run: `swift test`

Expected: All tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/FooTinderPad/Input/InputDispatcher.swift \
        Tests/FooTinderPadTests/InputDispatcherTests.swift
git commit -m "$(cat <<'EOF'
feat(input): emit touchpad surface deltas through InputDispatcher

Wires TouchpadProcessor into the per-tick pipeline. Y-axis is inverted
in mouse role (matches stick mouse) and not inverted in scroll role.
drainHeldInputs() resets touchpad state alongside dpad / repeater.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire `pad.touchpadOne` in `ControllerManager`

**Files:**
- Modify: `Sources/FooTinderPad/Controller/ControllerManager.swift`

`GCControllerTouchpad` is exposed as `pad.touchpadOne` on
`GCDualSenseGamepad` and `GCDualShockGamepad`. Other extended-gamepad
shapes do not have a touchpad surface, so the wiring is silently
skipped (matches existing behaviour for `touchpadButton`).

`GCControllerTouchpad.touchSurface` is a `GCControllerDirectionPad` —
it has a `valueChangedHandler` that fires with `(self, x, y)`. We use
it to forward `(x, y, touched)` into `dispatcher.handleTouchpad`.

For "is the finger currently touching", we use the zero-zero heuristic
(`x != 0 || y != 0`). The framework reports (0, 0) when the touch is
released, so this works in practice; a real touch landing exactly at
dead-centre is rare and only loses one delta tick. See Step 2's
implementation note for the `touchSurfaceButton` alternative.

**This task has no unit-test coverage.** `ControllerManager` is not
unit-tested anywhere in the repo because it depends on the
GameController framework, which cannot be mocked easily. Verification
is by manual smoke test.

- [ ] **Step 1: Add the `touchpadOne(of:)` helper**

In `Sources/FooTinderPad/Controller/ControllerManager.swift`,
immediately after the existing `private static func touchpadButton(of
pad:)` (around line 91–97), add:

```swift
    /// Touchpad surface (single-finger) — only present on PS4 (DualShock) /
    /// PS5 (DualSense). Returns nil for other extended-gamepad-shaped
    /// controllers, in which case the surface wiring is silently skipped.
    private static func touchpadOne(of pad: GCExtendedGamepad) -> GCControllerTouchpad? {
        if let ds = pad as? GCDualSenseGamepad { return ds.touchpadOne }
        if let ds = pad as? GCDualShockGamepad { return ds.touchpadOne }
        return nil
    }
```

- [ ] **Step 2: Wire the surface in `wire(_:)`**

In the same file, inside `private func wire(_ c: GCController)`,
immediately after the touchpad-click wiring block (the `if let touchpad
= Self.touchpadButton(of: pad) { ... }` block around lines 137–142),
add:

```swift
        // PS4/PS5 touchpad surface (single-finger, delta mode).
        if let surface = Self.touchpadOne(of: pad) {
            surface.touchSurface.valueChangedHandler = { [weak dispatcher] _, x, y in
                // Heuristic: if both axes report exactly zero, treat as
                // "no finger present". The framework reports (0, 0) when
                // the touch is released; a real touch landing exactly at
                // dead-centre is rare and only loses one delta tick.
                let touched = (x != 0 || y != 0)
                dispatcher?.handleTouchpad(x: Double(x), y: Double(y), touched: touched)
            }
        }
```

> **Note on touch detection.** Apple's `GCControllerTouchpad` also
> exposes a `touchSurfaceButton` property meant to indicate per-touch
> finger presence (distinct from the gamepad-level `pad.touchpadButton`
> which is the whole-pad click). On platforms where it works, it is a
> stricter signal than the zero-zero heuristic. We deliberately stick
> with the heuristic here because (a) the API surface is well-defined
> and version-stable, and (b) the failure mode of the heuristic
> (one-tick delta loss when a finger lands exactly on dead-centre) is
> not visually noticeable. Implementers may upgrade to
> `touchSurfaceButton.isPressed` later if real users report drift.

- [ ] **Step 3: Clear the wiring in `unwireCurrent()`**

In the same file, inside `private func unwireCurrent()` (around
line 73–89), find the line that nils out `pad.rightThumbstick.valueChangedHandler`
and add the touchpad surface cleanup directly after it:

```swift
        if let surface = Self.touchpadOne(of: pad) {
            surface.touchSurface.valueChangedHandler = nil
        }
```

- [ ] **Step 4: Verify the project still builds**

Run: `swift build`

Expected: Builds with no errors.

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `swift test`

Expected: All tests pass (no new tests in this task).

- [ ] **Step 6: Manual smoke test on hardware** *(human-driven)*

This step requires a physical PS5 (DualSense) or PS4 (DualShock4)
controller paired to the Mac. Perform each check **in order**:

1. Append the following block to your local `~/Library/Application
   Support/FooTinderPad/config.json` (back it up first):
   ```json
   "touchpad": "scroll",
   "touchpadMouseSpeed": 300,
   "touchpadScrollSpeed": 20,
   ```
2. Run `swift run FooTinderPad` (or launch from Xcode). Verify the
   menu-bar icon appears.
3. **Scroll, single direction.** Open Safari on a long page. Place a
   finger on the controller's touchpad and slide upward. Expect: the
   page scrolls by an amount proportional to the swipe distance.
4. **Scroll, idle finger.** Hold a finger still on the touchpad for
   ~3 seconds. Expect: no scrolling at all (delta = 0).
5. **Scroll, lift-and-relanding.** Slide right, lift, then place
   finger somewhere else and slide left. Expect: no jump on landing,
   only the actual leftward slide produces leftward scroll.
6. **Click coexistence.** With `touchpadButton` still bound to
   `Fn+Ctrl+Up`, press the touchpad down (full click). Expect:
   Mission Control opens. Surface deltas during the click do not
   suppress the click.
7. **Mouse mode.** Change config to `"touchpad": "mouse"`. Save.
   (Hot-reload via the file-watcher should pick it up; if not, restart
   the app.) Slide finger up: cursor moves up. Slide left: cursor
   moves left.
8. **Mouse, idle finger.** Hold still: cursor does not drift.
9. **`none` mode.** Change config to `"touchpad": "none"`. Slide
   finger: no mouse / no scroll. The original `touchpadButton` click
   still works.
10. **Non-PS controller (if available).** Connect an Xbox controller.
    Verify the app does not crash and other inputs (sticks, buttons)
    still work — the touchpad wiring is silently skipped.

If any of these fail, do **not** mark the step complete; investigate
and adjust before proceeding to Task 7.

- [ ] **Step 7: Commit**

```bash
git add Sources/FooTinderPad/Controller/ControllerManager.swift
git commit -m "$(cat <<'EOF'
feat(controller): forward touchpad surface X/Y to InputDispatcher

Wires GCControllerTouchpad.touchSurface.valueChangedHandler on
DualSense / DualShock4 to dispatcher.handleTouchpad. Touch detection
prefers touchSurfaceButton.isPressed, falling back to a zero-zero
heuristic on the X/Y axes.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update embedded and bundled defaults

**Files:**
- Modify: `Resources/DefaultConfig.json`
- Modify: `Sources/FooTinderPad/Config/DefaultConfig.swift`
- Modify: `Tests/FooTinderPadTests/ConfigParserTests.swift`

The bundled / embedded default JSON should advertise the new fields so
new users see the touchpad knob exists. Default role stays `"none"`
to preserve backward compatibility with users who have not opted in.

- [ ] **Step 1: Add the fields to `Resources/DefaultConfig.json`**

In `Resources/DefaultConfig.json`, insert these three lines between
the existing `"rightStick": "scroll",` line and the `"bindings": {`
opening:

```json
  "touchpad": "none",
  "touchpadMouseSpeed": 300,
  "touchpadScrollSpeed": 20,
```

So the file becomes (top portion shown for context):

```json
{
  "deadzone": 0.15,
  "mouseSpeed": 15,
  "scrollSpeed": 2,
  "leftStick": "mouse",
  "rightStick": "scroll",
  "touchpad": "none",
  "touchpadMouseSpeed": 300,
  "touchpadScrollSpeed": 20,
  "bindings": {
    ...existing bindings...
  }
}
```

- [ ] **Step 2: Mirror in `Sources/FooTinderPad/Config/DefaultConfig.swift`**

In the embedded `static let json` literal (around line 7–33), add the
same three lines in the same position:

```swift
      "rightStick": "scroll",
      "touchpad": "none",
      "touchpadMouseSpeed": 300,
      "touchpadScrollSpeed": 20,
      "bindings": {
```

- [ ] **Step 3: Run the test suite**

Run: `swift test`

Expected: All tests pass — including the existing
`testParsesDefaultConfigCompletely` (which Task 1 already taught about
the new defaults).

- [ ] **Step 4: Commit**

```bash
git add Resources/DefaultConfig.json \
        Sources/FooTinderPad/Config/DefaultConfig.swift
git commit -m "$(cat <<'EOF'
chore(config): advertise touchpad fields in default configs

Adds touchpad / touchpadMouseSpeed / touchpadScrollSpeed to the
bundled and embedded fallback defaults so users see the knob in their
seeded config.json. Default role stays "none" — no behaviour change
for existing users.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Document the touchpad surface in README

**Files:**
- Modify: `README.md`

Add the touchpad surface to the role-table copy and the sample-config
block. Keep tone consistent with the existing zh-TW prose and follow
the table format already used for `dpad`.

- [ ] **Step 1: Update the prose paragraphs about role configuration**

In `README.md`, find the existing prose immediately after the button
table (around line 102–105):

```markdown
`leftStick` / `rightStick` 屬性接受 `"mouse"`、 `"scroll"`、 `"none"` 三種角色。

搖桿與 D-pad 的移動曲線寫在原始碼中, 不從 JSON config 調整。`dpad` 屬性接受 `"bindings"`、 `"mouse"`、 `"scroll"`、 `"none"` 四種角色。
預設設定使用 `"mouse"` 做線性滑鼠微移動；若想恢復方向鍵綁定, 設為 `"bindings"` 並在 `bindings` 裡加入 `dpadUp` / `dpadDown` / `dpadLeft` / `dpadRight`。
```

Insert this paragraph immediately after the `dpad` paragraph (so it
becomes the next thing the reader sees):

```markdown
`touchpad` 屬性接受 `"mouse"`、 `"scroll"`、 `"none"` 三種角色, 預設 `"none"`。僅 PS4 (DualShock4) / PS5 (DualSense) 控制器有此面。啟用後手指在觸控板上滑動會直接驅動滑鼠移動或捲動 (trackpad-style delta), 手指不動就不會輸出。`touchpadMouseSpeed` 預設 300, `touchpadScrollSpeed` 預設 20, 可獨立微調。整片觸控板按下 (click) 仍走 `touchpadButton` binding, 與表面滑動互不干擾。
```

- [ ] **Step 2: Update the sample-config JSON block**

In the same file, find the JSON example block (around line 107–132)
and add the three new fields after `"rightStick"`:

```json
  "leftStick": "mouse",
  "rightStick": "scroll",
  "touchpad": "scroll",
  "touchpadMouseSpeed": 300,
  "touchpadScrollSpeed": 20,
  "dpad": "mouse",
```

(Putting `touchpad: "scroll"` in the example shows readers the
practical "free up the right stick" use case; `none` is the *default*
but `"scroll"` is the *example*.)

- [ ] **Step 3: Verify the README renders sensibly**

Open `README.md` in any markdown previewer (or `cat README.md`) and
visually confirm the table row, paragraph, and JSON block flow without
broken markup.

Run: `swift test`

Expected: Pass — README change is documentation only, but a final
green test run is the single check that all eight tasks landed
cleanly.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: document the touchpad surface input role

Adds the touchpad, touchpadMouseSpeed, and touchpadScrollSpeed knobs
to the README role section and example config. Calls out that the
surface is delta-mode (trackpad-like), single-finger, PS4/PS5 only,
and coexists with the existing touchpadButton click binding.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Checklist (already applied)

**Spec coverage:**
- TouchpadRole enum + .none / .mouse / .scroll → Task 1
- touchpadMouseSpeed / touchpadScrollSpeed defaults & validation → Task 1, Task 2
- Unknown role string warning → Task 3
- TouchpadProcessor (delta, last reset on release, sub-pixel accumulation) → Task 4
- InputDispatcher integration (tick, drain, role-based invertY) → Task 5
- ControllerManager wiring (touchpadOne, DualSense / DualShock4 only) → Task 6
- Coexistence with touchpadButton click → covered by Task 5 / Task 6 (independent paths) and verified in smoke test
- Resources/DefaultConfig.json + DefaultConfig.swift updates → Task 7
- README documentation → Task 8

**Type / signature consistency:** `TouchpadProcessor.tick(x:y:touched:speed:tickScale:invertY:)` is consistent across the test file, the implementation, and the dispatcher's `emitTouchpad(...)` helper. `handleTouchpad(x:y:touched:)` is consistent across dispatcher tests, dispatcher source, and ControllerManager wiring.

**Placeholder scan:** No TBDs, no "implement later", no "similar to Task N", no unresolved references.
