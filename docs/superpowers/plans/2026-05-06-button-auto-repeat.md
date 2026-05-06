# Button Auto-Repeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hold a controller button bound to a key with `"repeat": true` and the key keeps firing at ~30 Hz after a 400 ms initial delay (analogous to holding Backspace on a real keyboard).

**Architecture:** A new `RepeatScheduler` records held-and-repeating buttons; the existing `TickLoop` (~60 Hz) drives it through `InputDispatcher.tick(dt:)`. A new `KeySynthesizer.repeatPress` re-emits only the main key (not modifiers) with the CGEvent autorepeat flag set. Per-binding opt-in via `"repeat": true`.

**Tech Stack:** Swift 5.9+, GameController.framework, CoreGraphics CGEvent, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-06-button-auto-repeat-design.md`

---

### Task 1: Extend `EventSink` protocol with `autorepeat` parameter

**Files:**
- Modify: `Sources/FooTinderPad/Input/EventSink.swift`
- Modify: `Sources/FooTinderPad/Input/KeySynthesizer.swift` (single internal call site for the new param)
- Modify: `Tests/FooTinderPadTests/RecordingSink.swift`
- Modify: `Tests/FooTinderPadTests/KeySynthesizerTests.swift` (mechanical: append `, false` to all `.keyEvent` 3-tuples)

This is a foundational signature change. Existing behavior is unchanged (autorepeat defaults to `false` at call sites). It enables Task 2 to use the flag.

- [ ] **Step 1: Update protocol + CGEventSink**

In `Sources/FooTinderPad/Input/EventSink.swift`, change the protocol method and `CGEventSink` implementation:

```swift
protocol EventSink: AnyObject {
    func mouseMove(deltaX: Int, deltaY: Int)
    func mouseButton(_ button: MouseButton, down: Bool)
    func scroll(deltaX: Int, deltaY: Int)
    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, autorepeat: Bool)
}
```

Update `CGEventSink.keyEvent` (around line 78):

```swift
func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, autorepeat: Bool) {
    guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
    ev.flags = flags
    if autorepeat {
        ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    }
    ev.post(tap: .cghidEventTap)
}
```

- [ ] **Step 2: Update KeySynthesizer's two call sites in `acquire` and `releaseMod`, and the `press`/`release`/`drain` paths**

In `Sources/FooTinderPad/Input/KeySynthesizer.swift`, every existing `sink.keyEvent(...)` call must add `autorepeat: false`:

```swift
sink.keyEvent(keyCode: main, down: true, flags: currentFlags(), autorepeat: false)
// ... and for keyUp:
sink.keyEvent(keyCode: main, down: false, flags: currentFlags(), autorepeat: false)
// ... in acquire:
sink.keyEvent(keyCode: kc, down: true, flags: currentFlags(), autorepeat: false)
// ... in releaseMod:
sink.keyEvent(keyCode: kc, down: false, flags: currentFlags(), autorepeat: false)
// ... in drain:
sink.keyEvent(keyCode: key, down: false, flags: currentFlags(), autorepeat: false)
```

There are 5 such call sites in the file. Add `autorepeat: false` to each.

- [ ] **Step 3: Update `RecordingSink` to record autorepeat**

In `Tests/FooTinderPadTests/RecordingSink.swift`, change the `.keyEvent` case to capture autorepeat:

```swift
enum Action: Equatable {
    case mouseMove(Int, Int)
    case mouseButton(MouseButton, Bool)
    case scroll(Int, Int)
    case keyEvent(CGKeyCode, Bool, CGEventFlags, Bool)   // last bool: autorepeat
}

func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, autorepeat: Bool) {
    actions.append(.keyEvent(keyCode, down, flags, autorepeat))
}
```

- [ ] **Step 4: Update existing `KeySynthesizerTests` assertions**

In `Tests/FooTinderPadTests/KeySynthesizerTests.swift`, every `.keyEvent(c, down, flags)` becomes `.keyEvent(c, down, flags, false)`. There are exactly 7 occurrences (search for `.keyEvent(`). Each becomes mechanically:

```swift
// before
.keyEvent(CGKeyCode(kVK_Space), true, [])
// after
.keyEvent(CGKeyCode(kVK_Space), true, [], false)
```

- [ ] **Step 5: Run build + tests, expect pass**

Run: `swift build && swift test`
Expected: build succeeds, all existing tests still pass (no functional change yet).

- [ ] **Step 6: Commit**

```bash
git add Sources/FooTinderPad/Input/EventSink.swift Sources/FooTinderPad/Input/KeySynthesizer.swift Tests/FooTinderPadTests/RecordingSink.swift Tests/FooTinderPadTests/KeySynthesizerTests.swift
git commit -m "$(cat <<'EOF'
refactor: thread autorepeat flag through EventSink protocol

No behavior change yet — every existing call site passes false. Wires
up the boolean so Task 2's KeySynthesizer.repeatPress can set the CGEvent
keyboardEventAutorepeat field on synthesized repeat keyDowns.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `KeySynthesizer.repeatPress`

**Files:**
- Modify: `Sources/FooTinderPad/Input/KeySynthesizer.swift`
- Modify: `Tests/FooTinderPadTests/KeySynthesizerTests.swift`

`repeatPress` re-emits only the main key's `keyDown` with `autorepeat: true`. Modifier ref-counts are NOT touched (they were already acquired by the original `press`).

- [ ] **Step 1: Write failing test for basic repeat**

Append to `Tests/FooTinderPadTests/KeySynthesizerTests.swift` (before the closing `}`):

```swift
func testRepeatPressEmitsOnlyMainKeyWithAutorepeat() {
    let sink = RecordingSink()
    let synth = KeySynthesizer(sink: sink)
    let key = ParsedKey(mainKey: CGKeyCode(kVK_Delete), modifiers: [])

    synth.press(key)
    sink.actions.removeAll()
    synth.repeatPress(key)

    XCTAssertEqual(sink.actions, [
        .keyEvent(CGKeyCode(kVK_Delete), true, [], true),
    ])
}

func testRepeatPressKeepsModifierAcquiredButOnlyResendsMainKey() {
    let sink = RecordingSink()
    let synth = KeySynthesizer(sink: sink)
    let combo = ParsedKey(mainKey: CGKeyCode(kVK_DownArrow), modifiers: [.leftShift])

    synth.press(combo)
    sink.actions.removeAll()
    synth.repeatPress(combo)
    synth.release(combo)

    // Repeat must NOT re-send the Shift keyDown, but the Shift FLAG must
    // still be on the repeated DownArrow event because Shift is held.
    XCTAssertEqual(sink.actions, [
        .keyEvent(CGKeyCode(kVK_DownArrow), true, .maskShift, true),     // repeat
        .keyEvent(CGKeyCode(kVK_DownArrow), false, .maskShift, false),   // release main
        .keyEvent(CGKeyCode(kVK_Shift), false, [], false),               // release modifier
    ])
}

func testRepeatPressOnModifierOnlyIsNoOp() {
    let sink = RecordingSink()
    let synth = KeySynthesizer(sink: sink)
    let modOnly = ParsedKey(mainKey: nil, modifiers: [.leftCtrl])

    synth.press(modOnly)
    sink.actions.removeAll()
    synth.repeatPress(modOnly)

    XCTAssertEqual(sink.actions, [], "modifier-only ParsedKey has no main key to repeat")
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `swift test --filter KeySynthesizerTests/testRepeatPressEmitsOnlyMainKeyWithAutorepeat`
Expected: FAIL — `repeatPress` not declared.

- [ ] **Step 3: Implement `repeatPress`**

In `Sources/FooTinderPad/Input/KeySynthesizer.swift`, add this method after `release(_:)` (around line 30):

```swift
/// Re-emits only the main key's keyDown with the autorepeat flag set, leaving
/// modifier ref-counts untouched. Used by RepeatScheduler for held-key auto-repeat.
func repeatPress(_ k: ParsedKey) {
    guard let main = k.mainKey else { return }
    sink.keyEvent(keyCode: main, down: true, flags: currentFlags(), autorepeat: true)
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `swift test --filter KeySynthesizerTests`
Expected: all tests in `KeySynthesizerTests` pass (10 total = 7 original + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Input/KeySynthesizer.swift Tests/FooTinderPadTests/KeySynthesizerTests.swift
git commit -m "$(cat <<'EOF'
feat: add KeySynthesizer.repeatPress for held-key auto-repeat

Re-emits only the main key's keyDown with autorepeat=true. Modifier
ref-counts stay untouched, so the modifier flag remains on the repeat
event without bumping its hold count.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add `repeat` field to schema

**Files:**
- Modify: `Sources/FooTinderPad/Config/Config.swift`
- Modify: `Sources/FooTinderPad/Input/InputDispatcher.swift` (pattern-match on `.key` adds new associated value)
- Modify: `Tests/FooTinderPadTests/ConfigParserTests.swift`

`ResolvedBinding.key` gains a `repeat: Bool` associated value. `RawBinding` gains an optional `repeat: Bool?`. The loader emits warnings when `repeat: true` is set on bindings that can't repeat (modifier-only key, mouseButton).

- [ ] **Step 1: Find every call site of `.key(` to know what will need updating**

Run: `grep -rn '\.key(mainKey' Sources Tests`
Expected: hits in `Config.swift` (loader builds .key), `InputDispatcher.swift` (pattern match), `ConfigParserTests.swift` (assertions). Note them.

- [ ] **Step 2: Write failing tests for `repeat` parsing**

Append to `Tests/FooTinderPadTests/ConfigParserTests.swift`:

```swift
func testRepeatTrueParses() throws {
    let json = #"""
    { "bindings": { "buttonA": { "type": "key", "key": "Backspace", "repeat": true } } }
    """#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.bindings[.buttonA],
                   .key(mainKey: CGKeyCode(kVK_Delete), modifiers: [], repeat: true))
    XCTAssertTrue(result.warnings.isEmpty)
}

func testRepeatDefaultsToFalseWhenMissing() throws {
    let json = #"""
    { "bindings": { "buttonA": { "type": "key", "key": "Space" } } }
    """#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    XCTAssertEqual(result.config.bindings[.buttonA],
                   .key(mainKey: CGKeyCode(kVK_Space), modifiers: [], repeat: false))
}

func testRepeatTrueOnModifierOnlyIsIgnoredWithWarning() throws {
    let json = #"""
    { "bindings": { "buttonA": { "type": "key", "key": "LeftShift", "repeat": true } } }
    """#.data(using: .utf8)!
    let result = try ConfigLoader.load(from: json)
    if case let .key(_, _, isRepeat) = result.config.bindings[.buttonA]! {
        XCTAssertFalse(isRepeat, "repeat must be ignored on modifier-only binding")
    } else {
        XCTFail("expected .key binding")
    }
    XCTAssertTrue(result.warnings.contains { $0.contains("repeat") && $0.contains("buttonA") })
}
```

You will also need to add `import Carbon.HIToolbox` to the top of the test file if it's not already there (for `kVK_Delete`, `kVK_Space`).

- [ ] **Step 3: Run tests, expect failure**

Run: `swift test --filter ConfigParserTests`
Expected: COMPILE FAILURE — `.key` enum case has wrong arity. That's the next step.

- [ ] **Step 4: Update `ResolvedBinding.key` to include `repeat`**

In `Sources/FooTinderPad/Config/Config.swift`, change the enum:

```swift
enum ResolvedBinding: Equatable {
    case key(mainKey: CGKeyCode?, modifiers: [ModifierKey], repeat: Bool)
    case mouseButton(MouseButton)
    case none
}
```

- [ ] **Step 5: Add `repeat` to `RawBinding`**

In the same file, update `RawBinding`:

```swift
private struct RawBinding: Decodable {
    let type: String
    let key: String?
    let button: MouseButton?
    let `repeat`: Bool?
}
```

(`repeat` is a Swift keyword — backticks required.)

- [ ] **Step 6: Update `ConfigLoader.load` to parse + validate `repeat`**

In the same file, in the `case "key":` branch (around line 102), replace the body:

```swift
case "key":
    guard let keyStr = rawBinding.key else {
        warnings.append("\(rawKey): key missing 'key' field — set to none")
        resolved[button] = ResolvedBinding.none
        continue
    }
    do {
        let parsed = try KeyParser.parse(keyStr)
        var wantsRepeat = rawBinding.repeat ?? false
        if wantsRepeat && parsed.mainKey == nil {
            warnings.append("\(rawKey): 'repeat' ignored on modifier-only binding")
            wantsRepeat = false
        }
        resolved[button] = .key(mainKey: parsed.mainKey, modifiers: parsed.modifiers, repeat: wantsRepeat)
    } catch {
        warnings.append("\(rawKey): could not parse '\(keyStr)' (\(error)) — set to none")
        resolved[button] = ResolvedBinding.none
    }
```

Also add a warning for `repeat: true` on `mouseButton` / `none`. In the `mouseButton` branch:

```swift
case "mouseButton":
    if rawBinding.repeat == true {
        warnings.append("\(rawKey): 'repeat' ignored on mouseButton binding")
    }
    if let m = rawBinding.button {
        resolved[button] = .mouseButton(m)
    } else { ... }
```

And in the `none` branch:

```swift
case "none":
    if rawBinding.repeat == true {
        warnings.append("\(rawKey): 'repeat' ignored on none binding")
    }
    resolved[button] = ResolvedBinding.none
```

- [ ] **Step 7: Update `InputDispatcher` pattern match**

In `Sources/FooTinderPad/Input/InputDispatcher.swift`, find:

```swift
case .key(let main, let mods):
    let parsed = ParsedKey(mainKey: main, modifiers: mods)
    if pressed { key.press(parsed) } else { key.release(parsed) }
```

Replace with (the new associated value is unused for now; Task 5 will use it):

```swift
case .key(let main, let mods, _):
    let parsed = ParsedKey(mainKey: main, modifiers: mods)
    if pressed { key.press(parsed) } else { key.release(parsed) }
```

- [ ] **Step 8: Update existing assertions in `ConfigParserTests`**

Find any `.key(mainKey: ..., modifiers: ...)` constructions and add `, repeat: false`. Search:

```bash
grep -n '\.key(mainKey' Tests/FooTinderPadTests/ConfigParserTests.swift
```

For each hit, append `, repeat: false` before the closing paren. Example:

```swift
// before
XCTAssertEqual(result.config.bindings[.buttonA], .key(mainKey: 0x31, modifiers: []))
// after
XCTAssertEqual(result.config.bindings[.buttonA], .key(mainKey: 0x31, modifiers: [], repeat: false))
```

- [ ] **Step 9: Run all tests**

Run: `swift test`
Expected: all tests pass (existing + 3 new from Step 2).

- [ ] **Step 10: Commit**

```bash
git add Sources/FooTinderPad/Config/Config.swift Sources/FooTinderPad/Input/InputDispatcher.swift Tests/FooTinderPadTests/ConfigParserTests.swift
git commit -m "$(cat <<'EOF'
feat: parse 'repeat' field on key bindings

Adds an optional 'repeat' field to RawBinding and a corresponding
associated value to ResolvedBinding.key. ConfigLoader warns when
'repeat: true' is set on a binding that cannot repeat (modifier-only
key, mouseButton, none) and treats it as false.

Wiring (RepeatScheduler) is added in a later commit; this one only
makes the schema and the dispatcher pattern match correct.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Build `RepeatScheduler` (new file + tests)

**Files:**
- Create: `Sources/FooTinderPad/Input/RepeatScheduler.swift`
- Create: `Tests/FooTinderPadTests/RepeatSchedulerTests.swift`

`RepeatScheduler` holds per-button state and decides when to emit a repeat. Emit is done via an injected closure for testability. Times are passed in (no internal `Date()` reads) so tests can use a fake clock.

- [ ] **Step 1: Write failing tests**

Create `Tests/FooTinderPadTests/RepeatSchedulerTests.swift`:

```swift
import XCTest
import Carbon.HIToolbox
@testable import FooTinderPad

final class RepeatSchedulerTests: XCTestCase {

    private let backspace = ParsedKey(mainKey: CGKeyCode(kVK_Delete), modifiers: [])

    func testNoEmitBeforeInitialDelay() {
        let scheduler = RepeatScheduler()
        var emits: [(ControllerButton, ParsedKey)] = []
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)

        scheduler.tick(now: 0.200) { btn, key in emits.append((btn, key)) }
        XCTAssertEqual(emits.count, 0)

        scheduler.tick(now: 0.399) { btn, key in emits.append((btn, key)) }
        XCTAssertEqual(emits.count, 0)
    }

    func testFirstRepeatAtInitialDelay() {
        let scheduler = RepeatScheduler()
        var emits = 0
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)

        scheduler.tick(now: 0.400) { _, _ in emits += 1 }
        XCTAssertEqual(emits, 1)
    }

    func testIntervalAfterInitialDelay() {
        let scheduler = RepeatScheduler()
        var emits = 0
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)

        scheduler.tick(now: 0.400) { _, _ in emits += 1 }   // 1
        scheduler.tick(now: 0.420) { _, _ in emits += 1 }   // < interval, no
        scheduler.tick(now: 0.433) { _, _ in emits += 1 }   // 2 (>= 33 ms after first)
        scheduler.tick(now: 0.466) { _, _ in emits += 1 }   // 3
        XCTAssertEqual(emits, 3)
    }

    func testStopHaltsRepeat() {
        let scheduler = RepeatScheduler()
        var emits = 0
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)
        scheduler.tick(now: 0.400) { _, _ in emits += 1 }   // 1
        scheduler.stop(button: .buttonX)
        scheduler.tick(now: 0.500) { _, _ in emits += 1 }   // none
        scheduler.tick(now: 1.000) { _, _ in emits += 1 }   // none
        XCTAssertEqual(emits, 1)
    }

    func testClearHaltsAll() {
        let scheduler = RepeatScheduler()
        var emits = 0
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)
        scheduler.start(button: .dpadUp, parsedKey: ParsedKey(mainKey: CGKeyCode(kVK_UpArrow), modifiers: []), now: 0)
        scheduler.tick(now: 0.400) { _, _ in emits += 1 }   // 2
        scheduler.clear()
        scheduler.tick(now: 1.000) { _, _ in emits += 1 }   // none
        XCTAssertEqual(emits, 2)
    }

    func testIndependentTimingPerButton() {
        let scheduler = RepeatScheduler()
        var emits: [ControllerButton] = []
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)
        scheduler.start(button: .dpadUp, parsedKey: backspace, now: 0.200)

        // At t=0.400, only buttonX has crossed initial delay (0.4s since press at t=0).
        scheduler.tick(now: 0.400) { btn, _ in emits.append(btn) }
        XCTAssertEqual(emits, [.buttonX])

        // At t=0.600, dpadUp now at 0.4s since press → first repeat for dpadUp;
        // buttonX is at t=0.6 with last emit at 0.4 → 0.2s elapsed, well > 0.033 → repeat.
        scheduler.tick(now: 0.600) { btn, _ in emits.append(btn) }
        XCTAssertTrue(emits.contains(.buttonX))
        XCTAssertTrue(emits.contains(.dpadUp))
    }

    func testRepeatedStartReplacesPreviousEntry() {
        let scheduler = RepeatScheduler()
        var emits = 0
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)
        // Re-press resets press time
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 1.000)
        scheduler.tick(now: 1.300) { _, _ in emits += 1 }   // < 0.4s after re-press
        XCTAssertEqual(emits, 0)
        scheduler.tick(now: 1.400) { _, _ in emits += 1 }   // 1
        XCTAssertEqual(emits, 1)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `swift test --filter RepeatSchedulerTests`
Expected: COMPILE FAILURE — `RepeatScheduler` doesn't exist.

- [ ] **Step 3: Implement `RepeatScheduler`**

Create `Sources/FooTinderPad/Input/RepeatScheduler.swift`:

```swift
import Foundation

/// Per-button hold tracker that emits repeat events on tick after an initial
/// delay, then at a fixed interval. Time is passed in by the caller so the
/// scheduler is fully deterministic for tests.
final class RepeatScheduler {
    static let initialDelay: TimeInterval = 0.400
    static let interval: TimeInterval = 0.033

    private struct Entry {
        let parsedKey: ParsedKey
        let pressTime: TimeInterval
        var lastEmitTime: TimeInterval
    }

    private var held: [ControllerButton: Entry] = [:]

    func start(button: ControllerButton, parsedKey: ParsedKey, now: TimeInterval) {
        held[button] = Entry(parsedKey: parsedKey, pressTime: now, lastEmitTime: 0)
    }

    func stop(button: ControllerButton) {
        held.removeValue(forKey: button)
    }

    func clear() {
        held.removeAll()
    }

    func tick(now: TimeInterval, emit: (ControllerButton, ParsedKey) -> Void) {
        for (button, entry) in held {
            let sincePress = now - entry.pressTime
            guard sincePress >= Self.initialDelay else { continue }

            // First emit after the initial delay; subsequent emits paced by interval.
            let shouldEmit: Bool
            if entry.lastEmitTime == 0 {
                shouldEmit = true
            } else {
                shouldEmit = (now - entry.lastEmitTime) >= Self.interval
            }
            if shouldEmit {
                emit(button, entry.parsedKey)
                held[button]?.lastEmitTime = now
            }
        }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Run: `swift test --filter RepeatSchedulerTests`
Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Input/RepeatScheduler.swift Tests/FooTinderPadTests/RepeatSchedulerTests.swift
git commit -m "$(cat <<'EOF'
feat: add RepeatScheduler

Tracks held buttons and decides when to emit a repeat event on tick.
Time and emit-callback are injected so the scheduler is deterministic
for testing — no internal Date() or DispatchTime use.

Hardcoded 400 ms initial delay + 33 ms interval per design spec.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire `RepeatScheduler` into `InputDispatcher`

**Files:**
- Modify: `Sources/FooTinderPad/Input/InputDispatcher.swift`

The dispatcher gains a `repeater` and a `clock` (`() -> TimeInterval`, default wall-clock). On press of a `.key` with `repeat: true` we start the scheduler entry; on release we stop it; on tick we let the scheduler emit; on drain we clear it.

- [ ] **Step 1: Update `InputDispatcher` definition**

In `Sources/FooTinderPad/Input/InputDispatcher.swift`, replace the class body up through `init`:

```swift
final class InputDispatcher {
    private let configProvider: () -> ResolvedConfig
    private let key: KeySynthesizer
    private let mouse: MouseSynthesizer
    private let clock: () -> TimeInterval
    private let repeater = RepeatScheduler()
    private var leftStick = StickProcessor(deadzone: 0.15)
    private var rightStick = StickProcessor(deadzone: 0.15)
    private var leftTrigger = TriggerHysteresis()
    private var rightTrigger = TriggerHysteresis()
    private var lastLeftX: Double = 0
    private var lastLeftY: Double = 0
    private var lastRightX: Double = 0
    private var lastRightY: Double = 0

    init(config: @escaping () -> ResolvedConfig,
         key: KeySynthesizer,
         mouse: MouseSynthesizer,
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.configProvider = config
        self.key = key
        self.mouse = mouse
        self.clock = clock
    }
```

- [ ] **Step 2: Wire `applyBinding` to start/stop the scheduler**

Replace the `applyBinding(_:pressed:)` body and `handleButton(_:pressed:)`:

```swift
func handleButton(_ button: ControllerButton, pressed: Bool) {
    guard let binding = configProvider().bindings[button] else { return }
    applyBinding(binding, button: button, pressed: pressed)
}

private func applyBinding(_ binding: ResolvedBinding, button: ControllerButton, pressed: Bool) {
    switch binding {
    case .none:
        return
    case .key(let main, let mods, let isRepeat):
        let parsed = ParsedKey(mainKey: main, modifiers: mods)
        if pressed {
            key.press(parsed)
            if isRepeat {
                repeater.start(button: button, parsedKey: parsed, now: clock())
            }
        } else {
            repeater.stop(button: button)
            key.release(parsed)
        }
    case .mouseButton(let b):
        mouse.button(b, down: pressed)
    }
}
```

Note `applyBinding` now takes `button` so it knows which scheduler entry to start/stop. The other call site (`handleTrigger`) eventually calls `handleButton(button, pressed:)` — that already passes a button name, no change there.

- [ ] **Step 3: Wire `tick` to drive the scheduler**

In the existing `tick(dt:)`, add the repeater drive at the start:

```swift
func tick(dt: Double) {
    repeater.tick(now: clock()) { [weak key] _, parsed in
        key?.repeatPress(parsed)
    }
    let cfg = configProvider()
    leftStick.deadzone = cfg.deadzone
    rightStick.deadzone = cfg.deadzone
    let scale = dt * 60
    emit(role: cfg.leftStick, x: lastLeftX, y: lastLeftY, speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed, processor: &leftStick, tickScale: scale)
    emit(role: cfg.rightStick, x: lastRightX, y: lastRightY, speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed, processor: &rightStick, tickScale: scale)
}
```

- [ ] **Step 4: Wire `drainHeldInputs` to clear the scheduler**

Update `drainHeldInputs`:

```swift
func drainHeldInputs() {
    repeater.clear()
    key.drain()
    mouse.drain()
}
```

- [ ] **Step 5: Run all tests**

Run: `swift test`
Expected: all pass. The dispatcher wasn't covered by direct unit tests, but if any tests reference `InputDispatcher` they should still compile (the `applyBinding` signature change is private; `handleButton` signature is unchanged).

- [ ] **Step 6: Smoke test — build and install**

Run:
```bash
make install
```

Expected: build succeeds, app launches. (Can't easily automate the runtime smoke test for repeat behavior — that comes in Task 6 once the user's config has `"repeat": true`.)

- [ ] **Step 7: Commit**

```bash
git add Sources/FooTinderPad/Input/InputDispatcher.swift
git commit -m "$(cat <<'EOF'
feat: drive RepeatScheduler from InputDispatcher

Press of a .key binding with repeat=true registers an entry; release
removes it; tick(dt:) calls scheduler.tick which fires KeySynthesizer
.repeatPress for any button whose initial delay elapsed and whose
interval has passed since the last emit. drainHeldInputs() now also
clears the scheduler so config swaps and controller switches don't
leave ghost repeats.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Add `"repeat": true` to user config + `easy-preset.json`

**Files:**
- Modify: `~/Library/Application Support/FooTinderPad/config.json`
- Modify: `docs/examples/easy-preset.json`

Buttons that should repeat: `dpadUp`, `dpadDown`, `dpadLeft`, `dpadRight` (cursor / UI navigation), and `buttonX` (Backspace).

- [ ] **Step 1: Update personal config**

In `~/Library/Application Support/FooTinderPad/config.json`, change:

```json
"buttonX": { "type": "key", "key": "Backspace", "repeat": true },
...
"dpadUp":    { "type": "key", "key": "Up",    "repeat": true },
"dpadDown":  { "type": "key", "key": "Down",  "repeat": true },
"dpadLeft":  { "type": "key", "key": "Left",  "repeat": true },
"dpadRight": { "type": "key", "key": "Right", "repeat": true },
```

(Hot-reload picks the change up within ~100 ms.)

- [ ] **Step 2: Smoke test (manual)**

In a text editor (Notes / TextEdit), hold ■ Square — should delete characters continuously. Hold dpad up/down in a long document — cursor should scroll continuously.

If anything misbehaves, abort and inspect via Console.app filtering on subsystem `com.purefuncinc.FooTinderPad`.

- [ ] **Step 3: Sync `docs/examples/easy-preset.json`**

Apply the same `"repeat": true` changes to `docs/examples/easy-preset.json`.

- [ ] **Step 4: Commit**

```bash
git add docs/examples/easy-preset.json
git commit -m "$(cat <<'EOF'
docs: enable auto-repeat on dpad and Backspace in easy-preset

These are the bindings where holding feels natural: dpad arrows for
UI / text cursor navigation, Square for continuous Backspace.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Document the `repeat` field in README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a `repeat` paragraph under `bindings` schema**

In `README.md`, after the "支援的按鍵" section (or wherever the binding object is described), add:

```markdown
### 自動重複 (auto-repeat)

`.key` 類型的 binding 可以加 `"repeat": true`,按住按鈕時對應鍵會以 ~30 Hz 連續重發 (400 ms 初始延遲後),類似實體鍵盤按住 Backspace 連刪。預設為 `false`,寫了 `"repeat": true` 但綁定是純修飾鍵 / mouseButton / none 的話會被忽略並產生 warning。

範例:

\`\`\`json
"buttonX": { "type": "key", "key": "Backspace", "repeat": true }
\`\`\`

`docs/examples/easy-preset.json` 預設在 dpad 四個方向跟 Square (Backspace) 上開啟 repeat。
```

(Replace the `\`\`\`` escapes with literal backticks in the actual file.)

- [ ] **Step 2: Update the easy-preset table to mention repeat**

In the existing 示範設定 table, add a small note next to D-pad and Square rows, e.g.:

```markdown
| ■ Square | Backspace (repeat) | 文字編輯刪除, 按住連續刪 |
| D-pad ↑↓←→ | 方向鍵 (repeat) | UI 導航 / 文字游標, 按住連續移動 |
```

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: document the 'repeat' binding field

Adds a short section explaining the opt-in flag, its defaults, and
which preset bindings use it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Final test + push

- [ ] **Step 1: Run full test suite**

Run: `swift test`
Expected: all tests pass — total count should be the previous 63 + 3 (new ConfigParser) + 3 (new KeySynthesizer) + 7 (RepeatScheduler) = 76, give or take.

- [ ] **Step 2: Build a fresh release and reinstall**

Run: `make install`
Expected: builds, signs, replaces app in `/Applications`, launches.

- [ ] **Step 3: Manual confirmation**

- Hold ■ Square in Notes — characters delete continuously after ~400 ms.
- Hold D-pad up in a long doc — cursor moves up continuously.
- Quick-tap ■ Square — single deletion only (initial delay isn't crossed).
- Hold Cross (mouse left) — single click, NO repeat (no `"repeat": true`).
- Hold Options (Cmd+C) — single copy, NO repeat (modifier+key combo, no `repeat`).

- [ ] **Step 4: Push**

Run:
```bash
git push
```

Expected: pushes to `origin/main`. Done.
