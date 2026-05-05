# Controller Input Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu-bar app that turns an Xbox / DualSense controller into a hot-configurable mouse + keyboard input device, using `GameController.framework` to read the controller and `CGEvent` posting to synthesize host input.

**Architecture:** Single-process AppKit `LSUIElement` app. `ControllerManager` (last-connected wins) feeds button/stick events into `InputDispatcher`, which routes them to `KeySynthesizer` and `MouseSynthesizer` (both behind an `EventSink` protocol so production posts CGEvents and tests record actions). A `CVDisplayLink`-driven `TickLoop` samples stick state at refresh rate. `ConfigManager` watches `~/Library/Application Support/FooTinderPad/config.json` via `DispatchSource` and atomically swaps a pre-resolved `ResolvedConfig` on each change.

**Tech Stack:** Swift 5.9, AppKit, GameController.framework, CoreGraphics (CGEvent), CoreVideo (CVDisplayLink), Carbon HIToolbox (kVK_ keyCode constants), Foundation DispatchSource, XCTest, SwiftPM, codesign, Makefile bundling.

**Spec:** `docs/superpowers/specs/2026-05-06-controller-input-bridge-design.md`

---

## File Map

**New source files (all under `Sources/FooTinderPad/`):**
- `Foundation/Types.swift` — `ControllerButton`, `ModifierKey`, `MouseButton`, `StickRole` enums.
- `Input/EventSink.swift` — `EventSink` protocol; `CGEventSink` production implementation.
- `Input/KeyParser.swift` — Parses `"Alt+Return"` / `"RightShift"` etc. into `ParsedKey`.
- `Input/KeySynthesizer.swift` — Modifier ref-counted key event posting via `EventSink`.
- `Input/MouseSynthesizer.swift` — Mouse move (delta on top of current cursor), scroll, button via `EventSink`.
- `Input/StickProcessor.swift` — Circular deadzone, refresh-rate-normalized linear curve, fractional accumulator.
- `Input/InputDispatcher.swift` — Routes `ControllerManager` events to synthesizers; trigger hysteresis.
- `Config/Config.swift` — `Config` Codable + `ResolvedConfig` runtime model + validation/resolution.
- `Config/ConfigManager.swift` — Filesystem load + `DispatchSource` watcher + atomic swap + drain on swap.
- `Config/DefaultConfig.swift` — In-memory hard-coded fallback `Config`.
- `Controller/ControllerSource.swift` — `protocol ControllerSource` (test seam) + `protocol ControllerEventConsumer`.
- `Controller/ControllerManager.swift` — Real `GCController` discovery + last-connected-wins + handler wiring.
- `Controller/Ticker.swift` — `protocol Ticker` (test seam).
- `Controller/TickLoop.swift` — `CVDisplayLink` driven `Ticker`.
- `System/AccessibilityGate.swift` — `AXIsProcessTrusted` check + onboarding NSAlert + 5 s polling.
- `System/Paths.swift` — Application Support paths.
- `UI/MenuBar.swift` — Status item + status line + Reload / Reveal / About / Quit.
- `AppDelegate.swift` — Composition root; replaces logic in `main.swift`.

**Modified:**
- `main.swift` — Trimmed to a 3-line bootstrap that creates `AppDelegate` and runs `NSApp`.
- `Package.swift` — Unchanged (no SwiftPM resources; resource bundling done by Makefile).
- `Makefile` — Adds `Resources/DefaultConfig.json` copy step + `test` target.

**Resources:**
- `Resources/DefaultConfig.json` — Moved from repo-root `config.json`. Bundled into `.app/Contents/Resources/`.

**Tests (under `Tests/FooTinderPadTests/`):**
- `KeyParserTests.swift`
- `StickProcessorTests.swift`
- `KeySynthesizerTests.swift`
- `MouseSynthesizerTests.swift`
- `ConfigParserTests.swift`
- `ConfigManagerTests.swift` — integration test on a temp file
- `TriggerHysteresisTests.swift`
- `RecordingSink.swift` — shared test helper.
- (existing) `SmokeTest.swift` — left untouched.

---

## Task 1: Project Plumbing — Move Default Config + Wire Makefile + `make test`

**Files:**
- Move: `config.json` → `Resources/DefaultConfig.json`
- Modify: `Makefile`

**Why:** The runtime path is `~/Library/Application Support/FooTinderPad/config.json`. The repo file becomes a bundled template the app copies on first launch. Wiring `make test` shaves friction off every later TDD cycle.

- [ ] **Step 1: Move the file**

```bash
git mv config.json Resources/DefaultConfig.json
```

- [ ] **Step 2: Add the resource copy + test target to Makefile**

Open `Makefile`. After the line `cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns` add:

```make
	cp Resources/DefaultConfig.json $(CONTENTS)/Resources/DefaultConfig.json
```

At the bottom of the file (after the `clean` target body), add:

```make
test:
	swift test
```

And add `test` to the `.PHONY` line so it reads:

```make
.PHONY: build app run clean icon install test
```

- [ ] **Step 3: Build the app and verify the resource is bundled**

Run:
```bash
make app
ls FooTinderPad.app/Contents/Resources/DefaultConfig.json
```

Expected: file exists. If `ls` fails the `cp` step is wrong.

- [ ] **Step 4: Verify tests still pass on the existing smoke test**

Run:
```bash
make test
```

Expected: `Test Suite 'All tests' passed` with at least the `SmokeTest.testTrue` line.

- [ ] **Step 5: Commit**

```bash
git add Resources/DefaultConfig.json Makefile
git rm config.json   # already staged via git mv but explicit is fine
git commit -m "chore: bundle DefaultConfig.json into .app, add make test"
```

---

## Task 2: Foundation Types

**Files:**
- Create: `Sources/FooTinderPad/Foundation/Types.swift`

**Why:** All other components reference these enums. Centralizing them avoids duplicate definitions and makes ownership obvious.

- [ ] **Step 1: Create the directory and file**

Run:
```bash
mkdir -p Sources/FooTinderPad/Foundation
```

Then write `Sources/FooTinderPad/Foundation/Types.swift`:

```swift
import Foundation

enum ControllerButton: String, CaseIterable, Hashable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftThumbstickButton, rightThumbstickButton
    case dpadUp, dpadDown, dpadLeft, dpadRight
}

enum MouseButton: String, Codable, Hashable {
    case left, right, middle
}

enum StickRole: String, Codable {
    case mouse, scroll, none
}

enum ModifierKey: Hashable, CaseIterable {
    case leftCtrl, rightCtrl
    case leftAlt, rightAlt
    case leftShift, rightShift
    case leftCmd, rightCmd
    case fn
}
```

- [ ] **Step 2: Compile**

Run:
```bash
swift build
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/Foundation/Types.swift
git commit -m "feat: add foundation enums (ControllerButton, ModifierKey, MouseButton, StickRole)"
```

---

## Task 3: KeyParser

**Files:**
- Create: `Sources/FooTinderPad/Input/KeyParser.swift`
- Create: `Tests/FooTinderPadTests/KeyParserTests.swift`

**Why:** Parses user-facing strings like `"Alt+Return"` into `(CGKeyCode?, [ModifierKey])` and uses `kVK_*` constants from `Carbon.HIToolbox`. Pure function — perfect for TDD. PC-style names with macOS aliases per spec § 3.

- [ ] **Step 1: Write the test file**

Run:
```bash
mkdir -p Sources/FooTinderPad/Input
```

Write `Tests/FooTinderPadTests/KeyParserTests.swift`:

```swift
import XCTest
import Carbon.HIToolbox
@testable import FooTinderPad

final class KeyParserTests: XCTestCase {
    func testArrowUp() {
        let r = try? KeyParser.parse("Up")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_UpArrow))
        XCTAssertEqual(r?.modifiers, [])
    }

    func testReturnIsKeyCode0x24() {
        let r = try? KeyParser.parse("Return")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Return))
        XCTAssertEqual(r?.modifiers, [])
    }

    func testAltReturnCombo() {
        let r = try? KeyParser.parse("Alt+Return")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Return))
        XCTAssertEqual(r?.modifiers, [.leftAlt])
    }

    func testCtrlShiftDigit() {
        let r = try? KeyParser.parse("Ctrl+Shift+4")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_ANSI_4))
        XCTAssertEqual(r?.modifiers, [.leftCtrl, .leftShift])
    }

    func testLowercaseAndAliases() {
        let r = try? KeyParser.parse("option+return")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Return))
        XCTAssertEqual(r?.modifiers, [.leftAlt])
    }

    func testWinAliasMapsToCmd() {
        let r = try? KeyParser.parse("Win+Space")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Space))
        XCTAssertEqual(r?.modifiers, [.leftCmd])
    }

    func testModifierOnlyRightShift() {
        let r = try? KeyParser.parse("RightShift")
        XCTAssertNil(r?.mainKey)
        XCTAssertEqual(r?.modifiers, [.rightShift])
    }

    func testBackspaceIs0x33() {
        let r = try? KeyParser.parse("Backspace")
        XCTAssertEqual(r?.mainKey, 0x33)
    }

    func testDeleteIsForwardDelete0x75() {
        let r = try? KeyParser.parse("Delete")
        XCTAssertEqual(r?.mainKey, 0x75)
    }

    func testEmptyRejected() {
        XCTAssertThrowsError(try KeyParser.parse(""))
    }

    func testUnknownTokenRejected() {
        XCTAssertThrowsError(try KeyParser.parse("Foo"))
    }

    func testTrailingPlusRejected() {
        XCTAssertThrowsError(try KeyParser.parse("Alt+"))
    }

    func testUnknownMainKeyRejected() {
        XCTAssertThrowsError(try KeyParser.parse("Alt+Foo"))
    }

    func testNonModifierBeforeFinalRejected() {
        XCTAssertThrowsError(try KeyParser.parse("A+B"))
    }
}
```

- [ ] **Step 2: Run tests, expect failures**

Run:
```bash
make test
```

Expected: compile error on `KeyParser` (does not exist yet). That's the red.

- [ ] **Step 3: Implement KeyParser**

Write `Sources/FooTinderPad/Input/KeyParser.swift`:

```swift
import Foundation
import Carbon.HIToolbox
import CoreGraphics

struct ParsedKey: Equatable {
    let mainKey: CGKeyCode?         // nil for modifier-only bindings
    let modifiers: [ModifierKey]    // order matches input string, deduplicated
}

enum KeyParseError: Error, CustomStringConvertible {
    case empty
    case unknownToken(String)
    case nonModifierBeforeFinal(String)
    case trailingSeparator

    var description: String {
        switch self {
        case .empty: return "empty key string"
        case .unknownToken(let t): return "unknown token: \(t)"
        case .nonModifierBeforeFinal(let t): return "non-modifier '\(t)' appeared before final position"
        case .trailingSeparator: return "trailing '+'"
        }
    }
}

enum KeyParser {

    static func parse(_ raw: String) throws -> ParsedKey {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KeyParseError.empty }

        let tokens = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.contains(where: { $0.isEmpty }) else { throw KeyParseError.trailingSeparator }

        // Single token: either a main key, or a modifier-only binding
        if tokens.count == 1 {
            let t = tokens[0].lowercased()
            if let mod = modifier(from: t) {
                return ParsedKey(mainKey: nil, modifiers: [mod])
            }
            if let code = mainKey(from: t) {
                return ParsedKey(mainKey: code, modifiers: [])
            }
            throw KeyParseError.unknownToken(tokens[0])
        }

        // Multiple tokens: all-but-last must be modifiers, last is main key
        var mods: [ModifierKey] = []
        for t in tokens.dropLast() {
            let lower = t.lowercased()
            guard let mod = modifier(from: lower) else {
                if mainKey(from: lower) != nil {
                    throw KeyParseError.nonModifierBeforeFinal(t)
                }
                throw KeyParseError.unknownToken(t)
            }
            if !mods.contains(mod) { mods.append(mod) }
        }
        let lastLower = tokens.last!.lowercased()
        guard let main = mainKey(from: lastLower) else {
            throw KeyParseError.unknownToken(tokens.last!)
        }
        return ParsedKey(mainKey: main, modifiers: mods)
    }

    private static func modifier(from token: String) -> ModifierKey? {
        switch token {
        case "ctrl", "control":         return .leftCtrl
        case "leftctrl", "leftcontrol": return .leftCtrl
        case "rightctrl", "rightcontrol": return .rightCtrl
        case "alt", "option", "opt":    return .leftAlt
        case "leftalt", "leftoption":   return .leftAlt
        case "rightalt", "rightoption": return .rightAlt
        case "shift":                   return .leftShift
        case "leftshift":               return .leftShift
        case "rightshift":              return .rightShift
        case "win", "cmd", "command":   return .leftCmd
        case "leftwin", "leftcmd", "leftcommand":   return .leftCmd
        case "rightwin", "rightcmd", "rightcommand": return .rightCmd
        case "fn":                      return .fn
        default: return nil
        }
    }

    private static func mainKey(from token: String) -> CGKeyCode? {
        // Single letters and digits
        if token.count == 1, let scalar = token.unicodeScalars.first {
            if scalar.value >= 0x61 && scalar.value <= 0x7A { return letterKeyCode(scalar) }
            if scalar.value >= 0x30 && scalar.value <= 0x39 { return digitKeyCode(scalar) }
        }
        // Function keys F1..F20
        if token.hasPrefix("f"), let n = Int(token.dropFirst()), (1...20).contains(n) {
            return functionKeyCode(n)
        }
        switch token {
        case "up":          return CGKeyCode(kVK_UpArrow)
        case "down":        return CGKeyCode(kVK_DownArrow)
        case "left":        return CGKeyCode(kVK_LeftArrow)
        case "right":       return CGKeyCode(kVK_RightArrow)
        case "space":       return CGKeyCode(kVK_Space)
        case "return":      return CGKeyCode(kVK_Return)
        case "tab":         return CGKeyCode(kVK_Tab)
        case "escape":      return CGKeyCode(kVK_Escape)
        case "backspace":   return CGKeyCode(kVK_Delete)         // 0x33: macOS "Delete" key (Backspace per PC convention)
        case "delete":      return CGKeyCode(kVK_ForwardDelete)  // 0x75
        case "home":        return CGKeyCode(kVK_Home)
        case "end":         return CGKeyCode(kVK_End)
        case "pageup":      return CGKeyCode(kVK_PageUp)
        case "pagedown":    return CGKeyCode(kVK_PageDown)
        case "minus":       return CGKeyCode(kVK_ANSI_Minus)
        case "equal":       return CGKeyCode(kVK_ANSI_Equal)
        case "leftbracket": return CGKeyCode(kVK_ANSI_LeftBracket)
        case "rightbracket":return CGKeyCode(kVK_ANSI_RightBracket)
        case "backslash":   return CGKeyCode(kVK_ANSI_Backslash)
        case "semicolon":   return CGKeyCode(kVK_ANSI_Semicolon)
        case "quote":       return CGKeyCode(kVK_ANSI_Quote)
        case "comma":       return CGKeyCode(kVK_ANSI_Comma)
        case "period":      return CGKeyCode(kVK_ANSI_Period)
        case "slash":       return CGKeyCode(kVK_ANSI_Slash)
        case "grave":       return CGKeyCode(kVK_ANSI_Grave)
        default: return nil
        }
    }

    private static func letterKeyCode(_ s: Unicode.Scalar) -> CGKeyCode {
        switch s {
        case "a": return CGKeyCode(kVK_ANSI_A); case "b": return CGKeyCode(kVK_ANSI_B)
        case "c": return CGKeyCode(kVK_ANSI_C); case "d": return CGKeyCode(kVK_ANSI_D)
        case "e": return CGKeyCode(kVK_ANSI_E); case "f": return CGKeyCode(kVK_ANSI_F)
        case "g": return CGKeyCode(kVK_ANSI_G); case "h": return CGKeyCode(kVK_ANSI_H)
        case "i": return CGKeyCode(kVK_ANSI_I); case "j": return CGKeyCode(kVK_ANSI_J)
        case "k": return CGKeyCode(kVK_ANSI_K); case "l": return CGKeyCode(kVK_ANSI_L)
        case "m": return CGKeyCode(kVK_ANSI_M); case "n": return CGKeyCode(kVK_ANSI_N)
        case "o": return CGKeyCode(kVK_ANSI_O); case "p": return CGKeyCode(kVK_ANSI_P)
        case "q": return CGKeyCode(kVK_ANSI_Q); case "r": return CGKeyCode(kVK_ANSI_R)
        case "s": return CGKeyCode(kVK_ANSI_S); case "t": return CGKeyCode(kVK_ANSI_T)
        case "u": return CGKeyCode(kVK_ANSI_U); case "v": return CGKeyCode(kVK_ANSI_V)
        case "w": return CGKeyCode(kVK_ANSI_W); case "x": return CGKeyCode(kVK_ANSI_X)
        case "y": return CGKeyCode(kVK_ANSI_Y); case "z": return CGKeyCode(kVK_ANSI_Z)
        default: fatalError("letterKeyCode called with non-letter: \(s)")
        }
    }

    private static func digitKeyCode(_ s: Unicode.Scalar) -> CGKeyCode {
        switch s {
        case "0": return CGKeyCode(kVK_ANSI_0); case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2); case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4); case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6); case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8); case "9": return CGKeyCode(kVK_ANSI_9)
        default: fatalError("digitKeyCode called with non-digit: \(s)")
        }
    }

    private static func functionKeyCode(_ n: Int) -> CGKeyCode? {
        switch n {
        case 1:  return CGKeyCode(kVK_F1);  case 2:  return CGKeyCode(kVK_F2)
        case 3:  return CGKeyCode(kVK_F3);  case 4:  return CGKeyCode(kVK_F4)
        case 5:  return CGKeyCode(kVK_F5);  case 6:  return CGKeyCode(kVK_F6)
        case 7:  return CGKeyCode(kVK_F7);  case 8:  return CGKeyCode(kVK_F8)
        case 9:  return CGKeyCode(kVK_F9);  case 10: return CGKeyCode(kVK_F10)
        case 11: return CGKeyCode(kVK_F11); case 12: return CGKeyCode(kVK_F12)
        case 13: return CGKeyCode(kVK_F13); case 14: return CGKeyCode(kVK_F14)
        case 15: return CGKeyCode(kVK_F15); case 16: return CGKeyCode(kVK_F16)
        case 17: return CGKeyCode(kVK_F17); case 18: return CGKeyCode(kVK_F18)
        case 19: return CGKeyCode(kVK_F19); case 20: return CGKeyCode(kVK_F20)
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run tests, expect green**

Run:
```bash
make test
```

Expected: all `KeyParserTests` pass, plus `SmokeTest.testTrue`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Input/KeyParser.swift Tests/FooTinderPadTests/KeyParserTests.swift
git commit -m "feat: KeyParser for PC-style key strings with macOS aliases"
```

---

## Task 4: StickProcessor

**Files:**
- Create: `Sources/FooTinderPad/Input/StickProcessor.swift`
- Create: `Tests/FooTinderPadTests/StickProcessorTests.swift`

**Why:** Pure math: circular deadzone, refresh-rate-normalized linear curve, fractional accumulator. Spec § 2.

- [ ] **Step 1: Write the test file**

Write `Tests/FooTinderPadTests/StickProcessorTests.swift`:

```swift
import XCTest
@testable import FooTinderPad

final class StickProcessorTests: XCTestCase {

    func testCircularDeadzoneSuppressesSmallVector() {
        var p = StickProcessor(deadzone: 0.15)
        let out = p.tick(x: 0.1, y: 0.1, speed: 15, tickScale: 1, invertY: true)
        XCTAssertEqual(out.deltaX, 0)
        XCTAssertEqual(out.deltaY, 0)
    }

    func testFullDeflectionEmitsFullSpeed() {
        var p = StickProcessor(deadzone: 0.15)
        let out = p.tick(x: 1.0, y: 0.0, speed: 15, tickScale: 1, invertY: true)
        XCTAssertEqual(out.deltaX, 15)
        XCTAssertEqual(out.deltaY, 0)
    }

    func testFractionalAccumulatorAccumulatesAcrossTicks() {
        var p = StickProcessor(deadzone: 0)
        // 10 ticks at "0.4 px/tick" total. Use small speed to force fractional.
        var totalX = 0
        for _ in 0..<10 {
            let out = p.tick(x: 0.4 / 15.0, y: 0, speed: 15, tickScale: 1, invertY: true)
            totalX += out.deltaX
        }
        XCTAssertEqual(totalX, 4)
    }

    func testEnteringDeadzoneResetsAccumulator() {
        var p = StickProcessor(deadzone: 0.15)
        // Build up accumulator just under whole pixel
        _ = p.tick(x: 0.05, y: 0, speed: 1, tickScale: 1, invertY: true) // skipped (in deadzone)
        let after = p.tick(x: 0, y: 0, speed: 1, tickScale: 1, invertY: true)
        XCTAssertEqual(after.deltaX, 0)
    }

    func testYAxisInvertedForMouseMode() {
        var p = StickProcessor(deadzone: 0)
        let out = p.tick(x: 0, y: 1.0, speed: 15, tickScale: 1, invertY: true)
        XCTAssertEqual(out.deltaY, -15)
    }

    func testYAxisNotInvertedForScrollMode() {
        var p = StickProcessor(deadzone: 0)
        let out = p.tick(x: 0, y: 1.0, speed: 5, tickScale: 1, invertY: false)
        XCTAssertEqual(out.deltaY, 5)
    }

    func testTickScaleScalesEmittedDelta() {
        var p120 = StickProcessor(deadzone: 0)
        let half = p120.tick(x: 1, y: 0, speed: 30, tickScale: 0.5, invertY: true)
        XCTAssertEqual(half.deltaX, 15)

        var p60 = StickProcessor(deadzone: 0)
        let full = p60.tick(x: 1, y: 0, speed: 30, tickScale: 1.0, invertY: true)
        XCTAssertEqual(full.deltaX, 30)
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run:
```bash
make test
```

Expected: compile error on `StickProcessor`.

- [ ] **Step 3: Implement StickProcessor**

Write `Sources/FooTinderPad/Input/StickProcessor.swift`:

```swift
import Foundation

struct StickEmit: Equatable {
    let deltaX: Int
    let deltaY: Int
}

struct StickProcessor {
    let deadzone: Double

    private var accumX: Double = 0
    private var accumY: Double = 0

    init(deadzone: Double) {
        self.deadzone = max(0.0, min(0.49, deadzone))
    }

    mutating func tick(x: Double, y: Double, speed: Double, tickScale: Double, invertY: Bool) -> StickEmit {
        let mag = (x * x + y * y).squareRoot()
        guard mag >= deadzone, mag > 0 else {
            accumX = 0; accumY = 0
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        let n = (mag - deadzone) / (1 - deadzone)
        let scale = n / mag
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
}
```

- [ ] **Step 4: Run tests, expect green**

Run:
```bash
make test
```

Expected: all StickProcessorTests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Input/StickProcessor.swift Tests/FooTinderPadTests/StickProcessorTests.swift
git commit -m "feat: StickProcessor with circular deadzone and fractional accumulator"
```

---

## Task 5: EventSink Protocol + RecordingSink Test Helper

**Files:**
- Create: `Sources/FooTinderPad/Input/EventSink.swift`
- Create: `Tests/FooTinderPadTests/RecordingSink.swift`

**Why:** Decouple synthesizer logic from `CGEvent` posting. Production `CGEventSink` lives in this same file (it's tiny and only-used here). `RecordingSink` records every call as an `Action` for assertions.

- [ ] **Step 1: Write the protocol + production impl**

Write `Sources/FooTinderPad/Input/EventSink.swift`:

```swift
import Foundation
import CoreGraphics

protocol EventSink: AnyObject {
    func mouseMove(deltaX: Int, deltaY: Int)
    func mouseButton(_ button: MouseButton, down: Bool)
    func scroll(deltaX: Int, deltaY: Int)
    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags)
}

final class CGEventSink: EventSink {

    func mouseMove(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        let cur = CGEvent(source: nil)?.location ?? .zero
        let target = CGPoint(x: cur.x + CGFloat(deltaX), y: cur.y + CGFloat(deltaY))
        let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)
        ev?.post(tap: .cghidEventTap)
    }

    func mouseButton(_ button: MouseButton, down: Bool) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let (type, cgButton): (CGEventType, CGMouseButton)
        switch (button, down) {
        case (.left, true):   (type, cgButton) = (.leftMouseDown, .left)
        case (.left, false):  (type, cgButton) = (.leftMouseUp, .left)
        case (.right, true):  (type, cgButton) = (.rightMouseDown, .right)
        case (.right, false): (type, cgButton) = (.rightMouseUp, .right)
        case (.middle, true): (type, cgButton) = (.otherMouseDown, .center)
        case (.middle, false):(type, cgButton) = (.otherMouseUp, .center)
        }
        let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: cgButton)
        ev?.post(tap: .cghidEventTap)
    }

    func scroll(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        let ev = CGEvent(scrollWheelEvent2Source: nil,
                         units: .line,
                         wheelCount: 2,
                         wheel1: Int32(deltaY),
                         wheel2: Int32(deltaX),
                         wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Write the test helper**

Write `Tests/FooTinderPadTests/RecordingSink.swift`:

```swift
import Foundation
import CoreGraphics
@testable import FooTinderPad

final class RecordingSink: EventSink {
    enum Action: Equatable {
        case mouseMove(Int, Int)
        case mouseButton(MouseButton, Bool)
        case scroll(Int, Int)
        case keyEvent(CGKeyCode, Bool, CGEventFlags)
    }

    private(set) var actions: [Action] = []

    func mouseMove(deltaX: Int, deltaY: Int)            { actions.append(.mouseMove(deltaX, deltaY)) }
    func mouseButton(_ button: MouseButton, down: Bool) { actions.append(.mouseButton(button, down)) }
    func scroll(deltaX: Int, deltaY: Int)               { actions.append(.scroll(deltaX, deltaY)) }
    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        actions.append(.keyEvent(keyCode, down, flags))
    }
}

extension CGEventFlags: @retroactive Equatable {
    public static func == (lhs: CGEventFlags, rhs: CGEventFlags) -> Bool { lhs.rawValue == rhs.rawValue }
}
```

- [ ] **Step 3: Build and run existing tests**

Run:
```bash
make test
```

Expected: all green; new files compile but aren't asserted on yet.

- [ ] **Step 4: Commit**

```bash
git add Sources/FooTinderPad/Input/EventSink.swift Tests/FooTinderPadTests/RecordingSink.swift
git commit -m "feat: EventSink protocol + CGEventSink + RecordingSink test helper"
```

---

## Task 6: KeySynthesizer (modifier ref-counting)

**Files:**
- Create: `Sources/FooTinderPad/Input/KeySynthesizer.swift`
- Create: `Tests/FooTinderPadTests/KeySynthesizerTests.swift`

**Why:** Owns the ref-count state machine that lets shared modifiers (`Alt+Return` + `Alt+Tab`) coexist correctly. Translates `ParsedKey` press/release into `EventSink` calls.

- [ ] **Step 1: Write the test file**

Write `Tests/FooTinderPadTests/KeySynthesizerTests.swift`:

```swift
import XCTest
import Carbon.HIToolbox
@testable import FooTinderPad

final class KeySynthesizerTests: XCTestCase {

    func testSinglePressEmitsKeyDownThenUp() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)

        synth.press(ParsedKey(mainKey: CGKeyCode(kVK_Space), modifiers: []))
        synth.release(ParsedKey(mainKey: CGKeyCode(kVK_Space), modifiers: []))

        XCTAssertEqual(sink.actions, [
            .keyEvent(CGKeyCode(kVK_Space), true, []),
            .keyEvent(CGKeyCode(kVK_Space), false, []),
        ])
    }

    func testComboEmitsModThenMainOnPressAndReverseOnRelease() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        let combo = ParsedKey(mainKey: CGKeyCode(kVK_Return), modifiers: [.leftAlt])

        synth.press(combo)
        synth.release(combo)

        XCTAssertEqual(sink.actions, [
            .keyEvent(CGKeyCode(kVK_Option), true, .maskAlternate),
            .keyEvent(CGKeyCode(kVK_Return), true, .maskAlternate),
            .keyEvent(CGKeyCode(kVK_Return), false, .maskAlternate),
            .keyEvent(CGKeyCode(kVK_Option), false, []),
        ])
    }

    func testSharedModifierIsRefCountedAcrossOverlappingPresses() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        let altReturn = ParsedKey(mainKey: CGKeyCode(kVK_Return), modifiers: [.leftAlt])
        let altTab    = ParsedKey(mainKey: CGKeyCode(kVK_Tab),    modifiers: [.leftAlt])

        synth.press(altReturn)
        synth.press(altTab)
        synth.release(altReturn)         // Alt should NOT lift yet
        synth.release(altTab)            // Now Alt lifts

        // Find Alt down/up events
        let altKeyCode = CGKeyCode(kVK_Option)
        let altDowns = sink.actions.filter { $0 == .keyEvent(altKeyCode, true, .maskAlternate) }
        let altUps   = sink.actions.filter {
            if case let .keyEvent(c, down, _) = $0 { return c == altKeyCode && down == false }
            return false
        }
        XCTAssertEqual(altDowns.count, 1, "Alt keyDown should be sent only once")
        XCTAssertEqual(altUps.count, 1,   "Alt keyUp should be sent only once after both releases")
    }

    func testModifierOnlyHoldRelease() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        let modOnly = ParsedKey(mainKey: nil, modifiers: [.rightShift])

        synth.press(modOnly)
        synth.release(modOnly)

        XCTAssertEqual(sink.actions, [
            .keyEvent(CGKeyCode(kVK_RightShift), true, .maskShift),
            .keyEvent(CGKeyCode(kVK_RightShift), false, []),
        ])
    }

    func testUnderflowReleaseIsNoOp() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        let altReturn = ParsedKey(mainKey: CGKeyCode(kVK_Return), modifiers: [.leftAlt])

        // Release without prior press: must not crash, must emit no Alt keyUp
        synth.release(altReturn)
        let altUps = sink.actions.contains { action in
            if case let .keyEvent(_, down, _) = action { return down == false }
            return false
        }
        XCTAssertFalse(altUps, "no key events when releasing without prior press")
    }

    func testFnFlagAppliedToMainKeyButNoFnKeyEvent() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        let combo = ParsedKey(mainKey: CGKeyCode(kVK_UpArrow), modifiers: [.fn])

        synth.press(combo)
        synth.release(combo)

        XCTAssertEqual(sink.actions, [
            .keyEvent(CGKeyCode(kVK_UpArrow), true, .maskSecondaryFn),
            .keyEvent(CGKeyCode(kVK_UpArrow), false, .maskSecondaryFn),
        ])
    }

    func testDrainReleasesEverythingHeld() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        synth.press(ParsedKey(mainKey: CGKeyCode(kVK_Return), modifiers: [.leftAlt]))
        sink.actions.removeAll()
        synth.drain()

        let altKeyCode = CGKeyCode(kVK_Option)
        let returnKeyCode = CGKeyCode(kVK_Return)
        let names = sink.actions.compactMap { action -> (CGKeyCode, Bool)? in
            if case let .keyEvent(c, down, _) = action { return (c, down) }
            return nil
        }
        XCTAssertTrue(names.contains(where: { $0 == (returnKeyCode, false) }))
        XCTAssertTrue(names.contains(where: { $0 == (altKeyCode, false) }))
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure on `KeySynthesizer`**

Run:
```bash
make test
```

Expected: compile error.

- [ ] **Step 3: Implement KeySynthesizer**

Write `Sources/FooTinderPad/Input/KeySynthesizer.swift`:

```swift
import Foundation
import Carbon.HIToolbox
import CoreGraphics
import os

final class KeySynthesizer {
    private let sink: EventSink
    private var modCount: [ModifierKey: Int] = [:]
    private var heldMainKeys: Set<CGKeyCode> = []
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "KeySynthesizer")

    init(sink: EventSink) {
        self.sink = sink
    }

    func press(_ k: ParsedKey) {
        for m in k.modifiers { acquire(m) }
        if let main = k.mainKey {
            sink.keyEvent(keyCode: main, down: true, flags: currentFlags())
            heldMainKeys.insert(main)
        }
    }

    func release(_ k: ParsedKey) {
        if let main = k.mainKey, heldMainKeys.contains(main) {
            sink.keyEvent(keyCode: main, down: false, flags: currentFlags())
            heldMainKeys.remove(main)
        }
        for m in k.modifiers.reversed() { releaseMod(m) }
    }

    /// Releases every held key + modifier. Used on config swap and controller switch.
    func drain() {
        for key in heldMainKeys {
            sink.keyEvent(keyCode: key, down: false, flags: currentFlags())
        }
        heldMainKeys.removeAll()
        for (mod, count) in modCount where count > 0 {
            for _ in 0..<count { releaseMod(mod) }
        }
    }

    // MARK: - private

    private func acquire(_ m: ModifierKey) {
        let prev = modCount[m] ?? 0
        modCount[m] = prev + 1
        if prev == 0, let kc = keyCode(for: m) {
            sink.keyEvent(keyCode: kc, down: true, flags: currentFlags())
        }
    }

    private func releaseMod(_ m: ModifierKey) {
        let prev = modCount[m] ?? 0
        guard prev > 0 else {
            log.warning("releaseMod underflow on \(String(describing: m), privacy: .public)")
            return
        }
        modCount[m] = prev - 1
        if prev == 1, let kc = keyCode(for: m) {
            // currentFlags() now excludes this modifier because count just dropped to 0
            sink.keyEvent(keyCode: kc, down: false, flags: currentFlags())
        }
    }

    private func currentFlags() -> CGEventFlags {
        var f: CGEventFlags = []
        for (m, c) in modCount where c > 0 {
            switch m {
            case .leftCtrl, .rightCtrl:   f.insert(.maskControl)
            case .leftAlt,  .rightAlt:    f.insert(.maskAlternate)
            case .leftShift,.rightShift:  f.insert(.maskShift)
            case .leftCmd,  .rightCmd:    f.insert(.maskCommand)
            case .fn:                     f.insert(.maskSecondaryFn)
            }
        }
        return f
    }

    private func keyCode(for m: ModifierKey) -> CGKeyCode? {
        switch m {
        case .leftCtrl:   return CGKeyCode(kVK_Control)
        case .rightCtrl:  return CGKeyCode(kVK_RightControl)
        case .leftAlt:    return CGKeyCode(kVK_Option)
        case .rightAlt:   return CGKeyCode(kVK_RightOption)
        case .leftShift:  return CGKeyCode(kVK_Shift)
        case .rightShift: return CGKeyCode(kVK_RightShift)
        case .leftCmd:    return CGKeyCode(kVK_Command)
        case .rightCmd:   return CGKeyCode(kVK_RightCommand)
        case .fn:         return nil
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run:
```bash
make test
```

Expected: all `KeySynthesizerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Input/KeySynthesizer.swift Tests/FooTinderPadTests/KeySynthesizerTests.swift
git commit -m "feat: KeySynthesizer with modifier ref-counting and Fn-flag handling"
```

---

## Task 7: MouseSynthesizer

**Files:**
- Create: `Sources/FooTinderPad/Input/MouseSynthesizer.swift`
- Create: `Tests/FooTinderPadTests/MouseSynthesizerTests.swift`

**Why:** Thin wrapper that converts `(deltaX, deltaY)` and `(MouseButton, down)` into `EventSink` calls. Most logic lives in `CGEventSink`; this layer exists so `InputDispatcher` can talk to a stable synthesizer interface and tests can record the calls.

- [ ] **Step 1: Write the test**

Write `Tests/FooTinderPadTests/MouseSynthesizerTests.swift`:

```swift
import XCTest
@testable import FooTinderPad

final class MouseSynthesizerTests: XCTestCase {
    func testForwardsMouseMove() {
        let sink = RecordingSink()
        let m = MouseSynthesizer(sink: sink)
        m.move(deltaX: 5, deltaY: -3)
        XCTAssertEqual(sink.actions, [.mouseMove(5, -3)])
    }

    func testForwardsScroll() {
        let sink = RecordingSink()
        let m = MouseSynthesizer(sink: sink)
        m.scroll(deltaX: 1, deltaY: 2)
        XCTAssertEqual(sink.actions, [.scroll(1, 2)])
    }

    func testForwardsButton() {
        let sink = RecordingSink()
        let m = MouseSynthesizer(sink: sink)
        m.button(.right, down: true)
        m.button(.right, down: false)
        XCTAssertEqual(sink.actions, [.mouseButton(.right, true), .mouseButton(.right, false)])
    }

    func testZeroDeltaSuppressed() {
        let sink = RecordingSink()
        let m = MouseSynthesizer(sink: sink)
        m.move(deltaX: 0, deltaY: 0)
        m.scroll(deltaX: 0, deltaY: 0)
        XCTAssertTrue(sink.actions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run:
```bash
make test
```

Expected: compile error.

- [ ] **Step 3: Implement MouseSynthesizer**

Write `Sources/FooTinderPad/Input/MouseSynthesizer.swift`:

```swift
import Foundation

final class MouseSynthesizer {
    private let sink: EventSink
    private var heldButtons: Set<MouseButton> = []

    init(sink: EventSink) {
        self.sink = sink
    }

    func move(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        sink.mouseMove(deltaX: deltaX, deltaY: deltaY)
    }

    func scroll(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        sink.scroll(deltaX: deltaX, deltaY: deltaY)
    }

    func button(_ b: MouseButton, down: Bool) {
        if down {
            guard !heldButtons.contains(b) else { return }
            heldButtons.insert(b)
            sink.mouseButton(b, down: true)
        } else {
            guard heldButtons.contains(b) else { return }
            heldButtons.remove(b)
            sink.mouseButton(b, down: false)
        }
    }

    /// Releases every held mouse button. Used on config swap and controller switch.
    func drain() {
        for b in heldButtons {
            sink.mouseButton(b, down: false)
        }
        heldButtons.removeAll()
    }
}
```

- [ ] **Step 4: Run tests, expect green**

Run:
```bash
make test
```

Expected: all `MouseSynthesizerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Input/MouseSynthesizer.swift Tests/FooTinderPadTests/MouseSynthesizerTests.swift
git commit -m "feat: MouseSynthesizer with held-button tracking and drain"
```

---

## Task 8: Config Codable + ResolvedConfig

**Files:**
- Create: `Sources/FooTinderPad/Config/Config.swift`
- Create: `Tests/FooTinderPadTests/ConfigParserTests.swift`

**Why:** Parses raw JSON into `Config`, then resolves into `ResolvedConfig` (strongly-typed buttons, pre-parsed key strings). Validation clamps and warns per spec § 4.

- [ ] **Step 1: Write the test file**

Write `Tests/FooTinderPadTests/ConfigParserTests.swift`:

```swift
import XCTest
@testable import FooTinderPad

final class ConfigParserTests: XCTestCase {

    func testParsesDefaultConfigCompletely() throws {
        let json = """
        {
          "deadzone": 0.15,
          "mouseSpeed": 15,
          "scrollSpeed": 5,
          "leftStick": "mouse",
          "rightStick": "scroll",
          "bindings": {
            "buttonA": { "type": "key", "key": "Space" },
            "buttonB": { "type": "key", "key": "Return" },
            "buttonX": { "type": "mouseButton", "button": "left" },
            "buttonY": { "type": "key", "key": "Backspace" },
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
        """.data(using: .utf8)!

        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.15)
        XCTAssertEqual(result.config.mouseSpeed, 15)
        XCTAssertEqual(result.config.scrollSpeed, 5)
        XCTAssertEqual(result.config.leftStick, .mouse)
        XCTAssertEqual(result.config.rightStick, .scroll)
        XCTAssertEqual(result.config.bindings.count, 14)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMissingFieldsUseDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.15)
        XCTAssertEqual(result.config.mouseSpeed, 15)
        XCTAssertEqual(result.config.scrollSpeed, 5)
        XCTAssertEqual(result.config.leftStick, .mouse)
        XCTAssertEqual(result.config.rightStick, .scroll)
    }

    func testNegativeDeadzoneIsClampedWithWarning() throws {
        let json = #"{"deadzone": -0.1}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.0)
        XCTAssertTrue(result.warnings.contains { $0.contains("deadzone") })
    }

    func testTooLargeDeadzoneIsClampedWithWarning() throws {
        let json = #"{"deadzone": 0.8}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.49)
        XCTAssertTrue(result.warnings.contains { $0.contains("deadzone") })
    }

    func testZeroMouseSpeedFallsBackToDefault() throws {
        let json = #"{"mouseSpeed": 0}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.mouseSpeed, 15)
        XCTAssertTrue(result.warnings.contains { $0.contains("mouseSpeed") })
    }

    func testUnknownButtonNameIsDropped() throws {
        let json = #"""
        { "bindings": { "buttonZ": { "type": "key", "key": "Space" } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA], .none)
        XCTAssertTrue(result.warnings.contains { $0.contains("buttonZ") })
    }

    func testUnparsableKeyBecomesNoneWithWarning() throws {
        let json = #"""
        { "bindings": { "buttonA": { "type": "key", "key": "Foo" } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA], .none)
        XCTAssertTrue(result.warnings.contains { $0.contains("buttonA") })
    }

    func testPartialBindingsFillRestWithNone() throws {
        let json = #"""
        { "bindings": { "buttonA": { "type": "key", "key": "Space" } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA], .key(mainKey: 0x31, modifiers: []))
        XCTAssertEqual(result.config.bindings[.buttonB], .none)
        XCTAssertEqual(result.config.bindings.count, ControllerButton.allCases.count)
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run:
```bash
make test
```

Expected: compile error.

- [ ] **Step 3: Implement Config + ConfigLoader**

Run:
```bash
mkdir -p Sources/FooTinderPad/Config
```

Write `Sources/FooTinderPad/Config/Config.swift`:

```swift
import Foundation
import CoreGraphics

// MARK: - Resolved (runtime) model

struct ResolvedConfig: Equatable {
    let deadzone: Double
    let mouseSpeed: Double
    let scrollSpeed: Double
    let leftStick: StickRole
    let rightStick: StickRole
    let bindings: [ControllerButton: ResolvedBinding]
}

enum ResolvedBinding: Equatable {
    case key(mainKey: CGKeyCode?, modifiers: [ModifierKey])
    case mouseButton(MouseButton)
    case none
}

// MARK: - Raw (JSON-shaped) model

private struct RawConfig: Decodable {
    var deadzone: Double?
    var mouseSpeed: Double?
    var scrollSpeed: Double?
    var leftStick: StickRole?
    var rightStick: StickRole?
    var bindings: [String: RawBinding]?
}

private struct RawBinding: Decodable {
    let type: String
    let key: String?
    let button: MouseButton?
}

// MARK: - Loader

struct LoadResult {
    let config: ResolvedConfig
    let warnings: [String]
}

enum ConfigLoader {

    static func load(from data: Data) throws -> LoadResult {
        let raw = try JSONDecoder().decode(RawConfig.self, from: data)
        var warnings: [String] = []

        // Numeric scalars
        var deadzone = raw.deadzone ?? 0.15
        if deadzone < 0 || deadzone > 0.49 {
            warnings.append("deadzone \(deadzone) out of range; clamped to [0.0, 0.49]")
            deadzone = max(0.0, min(0.49, deadzone))
        }
        var mouseSpeed = raw.mouseSpeed ?? 15
        if mouseSpeed <= 0 {
            warnings.append("mouseSpeed must be > 0; using default 15")
            mouseSpeed = 15
        }
        var scrollSpeed = raw.scrollSpeed ?? 5
        if scrollSpeed <= 0 {
            warnings.append("scrollSpeed must be > 0; using default 5")
            scrollSpeed = 5
        }

        let leftStick = raw.leftStick ?? .mouse
        let rightStick = raw.rightStick ?? .scroll

        // Bindings — start with all .none, then overlay valid ones
        var resolved: [ControllerButton: ResolvedBinding] = [:]
        for b in ControllerButton.allCases { resolved[b] = .none }

        for (rawKey, rawBinding) in (raw.bindings ?? [:]) {
            guard let button = ControllerButton(rawValue: rawKey) else {
                warnings.append("unknown button '\(rawKey)' — entry dropped")
                continue
            }
            switch rawBinding.type {
            case "none":
                resolved[button] = .none
            case "mouseButton":
                if let m = rawBinding.button {
                    resolved[button] = .mouseButton(m)
                } else {
                    warnings.append("\(rawKey): mouseButton missing 'button' field — set to none")
                    resolved[button] = .none
                }
            case "key":
                guard let keyStr = rawBinding.key else {
                    warnings.append("\(rawKey): key missing 'key' field — set to none")
                    resolved[button] = .none
                    continue
                }
                do {
                    let parsed = try KeyParser.parse(keyStr)
                    resolved[button] = .key(mainKey: parsed.mainKey, modifiers: parsed.modifiers)
                } catch {
                    warnings.append("\(rawKey): could not parse '\(keyStr)' (\(error)) — set to none")
                    resolved[button] = .none
                }
            default:
                warnings.append("\(rawKey): unknown binding type '\(rawBinding.type)' — set to none")
                resolved[button] = .none
            }
        }

        let cfg = ResolvedConfig(
            deadzone: deadzone,
            mouseSpeed: mouseSpeed,
            scrollSpeed: scrollSpeed,
            leftStick: leftStick,
            rightStick: rightStick,
            bindings: resolved
        )
        return LoadResult(config: cfg, warnings: warnings)
    }
}
```

- [ ] **Step 4: Run tests, expect green**

Run:
```bash
make test
```

Expected: all `ConfigParserTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Config/Config.swift Tests/FooTinderPadTests/ConfigParserTests.swift
git commit -m "feat: Config Codable + ResolvedConfig + validation"
```

---

## Task 9: Paths Utility

**Files:**
- Create: `Sources/FooTinderPad/System/Paths.swift`

**Why:** Single source of truth for the user-writable config path.

- [ ] **Step 1: Implement Paths**

Run:
```bash
mkdir -p Sources/FooTinderPad/System
```

Write `Sources/FooTinderPad/System/Paths.swift`:

```swift
import Foundation

enum Paths {
    static let appName = "FooTinderPad"

    static var configURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("config.json")
    }

    static var bundledDefaultConfigURL: URL? {
        Bundle.main.url(forResource: "DefaultConfig", withExtension: "json")
    }

    static func ensureConfigDirectoryExists() throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
swift build
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/System/Paths.swift
git commit -m "feat: Paths helper for Application Support config location"
```

---

## Task 10: DefaultConfig fallback

**Files:**
- Create: `Sources/FooTinderPad/Config/DefaultConfig.swift`

**Why:** If the bundle resource is missing on some weird build path, we still need a working baseline so the app launches.

- [ ] **Step 1: Implement DefaultConfig**

Write `Sources/FooTinderPad/Config/DefaultConfig.swift`:

```swift
import Foundation

enum DefaultConfig {

    /// Embedded textual default — same content as Resources/DefaultConfig.json.
    /// Used when the bundle resource cannot be read (defensive fallback).
    static let json: String = #"""
    {
      "deadzone": 0.15,
      "mouseSpeed": 15,
      "scrollSpeed": 5,
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

    static var data: Data { json.data(using: .utf8)! }
}
```

- [ ] **Step 2: Build**

Run:
```bash
swift build
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/Config/DefaultConfig.swift
git commit -m "feat: in-memory DefaultConfig as last-resort fallback"
```

---

## Task 11: ConfigManager (load + hot reload)

**Files:**
- Create: `Sources/FooTinderPad/Config/ConfigManager.swift`
- Create: `Tests/FooTinderPadTests/ConfigManagerTests.swift`

**Why:** Owns the live `ResolvedConfig` and a `DispatchSource` that re-loads on file changes. On every swap it calls a "drain" closure so synthesizers can release any held inputs.

- [ ] **Step 1: Write the integration test**

Write `Tests/FooTinderPadTests/ConfigManagerTests.swift`:

```swift
import XCTest
@testable import FooTinderPad

final class ConfigManagerTests: XCTestCase {

    func testLoadFromDataFallbackChain() throws {
        // Direct loadOnce path is the unit being tested here; full filesystem
        // hot-reload is exercised in testReloadsOnFileWrite.
        let mgr = ConfigManager(configURLOverride: URL(fileURLWithPath: "/nonexistent/path/abcdef.json"))
        let result = mgr.loadOnce()
        XCTAssertEqual(result.config.deadzone, 0.15)
        XCTAssertEqual(result.config.bindings.count, ControllerButton.allCases.count)
    }

    func testReloadsOnFileWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        let initial = #"{"mouseSpeed": 10}"#
        try initial.write(to: url, atomically: true, encoding: .utf8)

        let mgr = ConfigManager(configURLOverride: url)
        var swaps: [Double] = []
        mgr.onSwap = { cfg in swaps.append(cfg.mouseSpeed) }

        mgr.start()
        XCTAssertEqual(mgr.current.mouseSpeed, 10)

        // Trigger a write that the DispatchSource will pick up
        let updated = #"{"mouseSpeed": 42}"#
        try updated.write(to: url, atomically: true, encoding: .utf8)

        let exp = expectation(description: "swap fires within 1s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if mgr.current.mouseSpeed == 42 { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(mgr.current.mouseSpeed, 42)
        XCTAssertTrue(swaps.contains(42))

        mgr.stop()
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run:
```bash
make test
```

Expected: compile error.

- [ ] **Step 3: Implement ConfigManager**

Write `Sources/FooTinderPad/Config/ConfigManager.swift`:

```swift
import Foundation
import os

final class ConfigManager {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "ConfigManager")
    private let url: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var debounce: DispatchWorkItem?
    private(set) var current: ResolvedConfig

    /// Called on the main queue every time the config is successfully reloaded.
    var onSwap: ((ResolvedConfig) -> Void)?
    /// Called whenever `current` changes; visible warnings (e.g. for menu bar surface).
    var onWarnings: (([String]) -> Void)?

    init(configURLOverride: URL? = nil) {
        self.url = configURLOverride ?? Paths.configURL
        self.current = ConfigManager.loadInitial(url: self.url)
    }

    func loadOnce() -> LoadResult {
        do {
            let data = try Data(contentsOf: url)
            return try ConfigLoader.load(from: data)
        } catch {
            log.warning("loadOnce failed (\(error.localizedDescription, privacy: .public)); using bundled default")
            do {
                let data = try ConfigManager.readBundledOrEmbeddedDefault()
                return try ConfigLoader.load(from: data)
            } catch {
                log.error("default config also unparseable: \(error.localizedDescription, privacy: .public)")
                return LoadResult(config: ResolvedConfig.empty, warnings: ["fallback to empty config"])
            }
        }
    }

    func start() {
        ensureFileExists()
        let r = loadOnce()
        current = r.config
        onSwap?(r.config)
        onWarnings?(r.warnings)
        armSource()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        debounce?.cancel()
        debounce = nil
    }

    func reloadNow() {
        let r = loadOnce()
        current = r.config
        onSwap?(r.config)
        onWarnings?(r.warnings)
    }

    // MARK: - private

    private func ensureFileExists() {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: url.path) else { return }
        do {
            let data = try ConfigManager.readBundledOrEmbeddedDefault()
            try data.write(to: url)
        } catch {
            log.error("could not seed default config: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func readBundledOrEmbeddedDefault() throws -> Data {
        if let bundled = Paths.bundledDefaultConfigURL {
            return try Data(contentsOf: bundled)
        }
        return DefaultConfig.data
    }

    private static func loadInitial(url: URL) -> ResolvedConfig {
        let mgr = ConfigManager(_internalURL: url)
        return mgr.loadOnce().config
    }

    private init(_internalURL url: URL) {
        self.url = url
        self.current = ResolvedConfig.empty
    }

    private func armSource() {
        source?.cancel()
        if fd >= 0 { close(fd); fd = -1 }

        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("open(O_EVTONLY) failed for \(self.url.path, privacy: .public)")
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        s.setEventHandler { [weak self] in self?.scheduleReload() }
        s.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = s
        s.resume()
    }

    private func scheduleReload() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performReload() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func performReload() {
        // The file may have been renamed by editors that write atomically.
        // Re-arm regardless of success so we keep watching the path.
        let r = loadOnce()
        current = r.config
        onSwap?(r.config)
        onWarnings?(r.warnings)
        armSource()
    }
}

extension ResolvedConfig {
    static let empty = ResolvedConfig(
        deadzone: 0.15,
        mouseSpeed: 15,
        scrollSpeed: 5,
        leftStick: .mouse,
        rightStick: .scroll,
        bindings: Dictionary(uniqueKeysWithValues: ControllerButton.allCases.map { ($0, .none) })
    )
}
```

- [ ] **Step 4: Run tests**

Run:
```bash
make test
```

Expected: all `ConfigManagerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/Config/ConfigManager.swift Tests/FooTinderPadTests/ConfigManagerTests.swift
git commit -m "feat: ConfigManager with DispatchSource hot reload + debounce"
```

---

## Task 12: InputDispatcher (trigger hysteresis)

**Files:**
- Create: `Sources/FooTinderPad/Input/InputDispatcher.swift`
- Create: `Tests/FooTinderPadTests/TriggerHysteresisTests.swift`

**Why:** Routes button / stick / trigger events to synthesizers. Triggers' analog 0.0–1.0 values are binarized with 0.55 / 0.45 hysteresis (spec § 3). Stick processors live here per-stick.

- [ ] **Step 1: Write the test**

Write `Tests/FooTinderPadTests/TriggerHysteresisTests.swift`:

```swift
import XCTest
@testable import FooTinderPad

final class TriggerHysteresisTests: XCTestCase {

    func testRisingPastUpperFiresPress() {
        var h = TriggerHysteresis()
        XCTAssertEqual(h.update(0.40), .none)
        XCTAssertEqual(h.update(0.55), .none)   // exactly upper does not yet fire
        XCTAssertEqual(h.update(0.60), .pressed)
    }

    func testFallingPastLowerFiresRelease() {
        var h = TriggerHysteresis()
        _ = h.update(0.80)   // pressed
        XCTAssertEqual(h.update(0.50), .none)   // between thresholds: hold
        XCTAssertEqual(h.update(0.40), .released)
    }

    func testStaysInPressedAcrossMidRange() {
        var h = TriggerHysteresis()
        _ = h.update(0.90)
        XCTAssertEqual(h.update(0.50), .none)
        XCTAssertEqual(h.update(0.46), .none)
        XCTAssertEqual(h.update(0.45), .none)
    }

    func testIdempotentAtFullDeflection() {
        var h = TriggerHysteresis()
        _ = h.update(0.99)
        XCTAssertEqual(h.update(1.00), .none) // already pressed, no event
    }
}
```

- [ ] **Step 2: Run tests, expect compile failure**

Run:
```bash
make test
```

Expected: compile error.

- [ ] **Step 3: Implement InputDispatcher and TriggerHysteresis**

Write `Sources/FooTinderPad/Input/InputDispatcher.swift`:

```swift
import Foundation

struct TriggerHysteresis {
    enum Edge { case none, pressed, released }
    private(set) var pressed = false
    mutating func update(_ value: Double) -> Edge {
        if !pressed && value > 0.55 { pressed = true; return .pressed }
        if pressed && value < 0.45 { pressed = false; return .released }
        return .none
    }
}

final class InputDispatcher {
    private let configProvider: () -> ResolvedConfig
    private let key: KeySynthesizer
    private let mouse: MouseSynthesizer
    private var leftStick = StickProcessor(deadzone: 0.15)
    private var rightStick = StickProcessor(deadzone: 0.15)
    private var leftTrigger = TriggerHysteresis()
    private var rightTrigger = TriggerHysteresis()
    private var lastLeftX: Double = 0
    private var lastLeftY: Double = 0
    private var lastRightX: Double = 0
    private var lastRightY: Double = 0

    init(config: @escaping () -> ResolvedConfig, key: KeySynthesizer, mouse: MouseSynthesizer) {
        self.configProvider = config
        self.key = key
        self.mouse = mouse
    }

    // MARK: - inbound from controller

    func handleButton(_ button: ControllerButton, pressed: Bool) {
        guard let binding = configProvider().bindings[button] else { return }
        applyBinding(binding, pressed: pressed)
    }

    func handleTrigger(_ button: ControllerButton, value: Double) {
        let edge: TriggerHysteresis.Edge
        switch button {
        case .leftTrigger:  edge = leftTrigger.update(value)
        case .rightTrigger: edge = rightTrigger.update(value)
        default: return
        }
        switch edge {
        case .pressed:  handleButton(button, pressed: true)
        case .released: handleButton(button, pressed: false)
        case .none:     break
        }
    }

    func updateLeftStick(x: Double, y: Double)  { lastLeftX = x; lastLeftY = y }
    func updateRightStick(x: Double, y: Double) { lastRightX = x; lastRightY = y }

    // MARK: - tick (called by TickLoop)

    func tick(dt: Double) {
        let cfg = configProvider()
        leftStick = StickProcessor(deadzoneAlias: cfg.deadzone, accumulator: leftStick)
        rightStick = StickProcessor(deadzoneAlias: cfg.deadzone, accumulator: rightStick)
        let scale = dt * 60
        emit(role: cfg.leftStick, x: lastLeftX, y: lastLeftY, speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed, processor: &leftStick, tickScale: scale)
        emit(role: cfg.rightStick, x: lastRightX, y: lastRightY, speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed, processor: &rightStick, tickScale: scale)
    }

    private func emit(role: StickRole, x: Double, y: Double, speedMouse: Double, speedScroll: Double, processor: inout StickProcessor, tickScale: Double) {
        switch role {
        case .none:
            return
        case .mouse:
            let out = processor.tick(x: x, y: y, speed: speedMouse, tickScale: tickScale, invertY: true)
            mouse.move(deltaX: out.deltaX, deltaY: out.deltaY)
        case .scroll:
            let out = processor.tick(x: x, y: y, speed: speedScroll, tickScale: tickScale, invertY: false)
            mouse.scroll(deltaX: out.deltaX, deltaY: out.deltaY)
        }
    }

    func drainHeldInputs() {
        key.drain()
        mouse.drain()
    }

    // MARK: - private

    private func applyBinding(_ binding: ResolvedBinding, pressed: Bool) {
        switch binding {
        case .none:
            return
        case .key(let main, let mods):
            let parsed = ParsedKey(mainKey: main, modifiers: mods)
            if pressed { key.press(parsed) } else { key.release(parsed) }
        case .mouseButton(let b):
            mouse.button(b, down: pressed)
        }
    }
}

private extension StickProcessor {
    /// Re-creates the processor when the deadzone changed via hot reload, but
    /// preserves the fractional accumulator so stick motion does not stutter.
    init(deadzoneAlias: Double, accumulator: StickProcessor) {
        self.init(deadzone: deadzoneAlias)
        self.copyAccumulator(from: accumulator)
    }
}

extension StickProcessor {
    fileprivate mutating func copyAccumulator(from other: StickProcessor) {
        // Accumulator fields are private; we re-import via a helper in the same
        // module. See StickProcessor.swift's `accum*` properties.
        self._copyAccumulatorBridge(from: other)
    }
}
```

- [ ] **Step 4: Add accumulator copy helper to StickProcessor**

Edit `Sources/FooTinderPad/Input/StickProcessor.swift`. Replace `private var accumX: Double = 0` and `private var accumY: Double = 0` with `internal`-scoped vars and add a copy helper. The full updated file:

```swift
import Foundation

struct StickEmit: Equatable {
    let deltaX: Int
    let deltaY: Int
}

struct StickProcessor {
    let deadzone: Double

    var accumX: Double = 0
    var accumY: Double = 0

    init(deadzone: Double) {
        self.deadzone = max(0.0, min(0.49, deadzone))
    }

    mutating func tick(x: Double, y: Double, speed: Double, tickScale: Double, invertY: Bool) -> StickEmit {
        let mag = (x * x + y * y).squareRoot()
        guard mag >= deadzone, mag > 0 else {
            accumX = 0; accumY = 0
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        let n = (mag - deadzone) / (1 - deadzone)
        let scale = n / mag
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

    mutating func _copyAccumulatorBridge(from other: StickProcessor) {
        self.accumX = other.accumX
        self.accumY = other.accumY
    }
}
```

- [ ] **Step 5: Run tests**

Run:
```bash
make test
```

Expected: all tests including `TriggerHysteresisTests` pass; existing `StickProcessorTests` still green.

- [ ] **Step 6: Commit**

```bash
git add Sources/FooTinderPad/Input/InputDispatcher.swift Sources/FooTinderPad/Input/StickProcessor.swift Tests/FooTinderPadTests/TriggerHysteresisTests.swift
git commit -m "feat: InputDispatcher with trigger hysteresis and per-stick processors"
```

---

## Task 13: ControllerManager

**Files:**
- Create: `Sources/FooTinderPad/Controller/ControllerManager.swift`

**Why:** Subscribes to `GCController.didConnectNotification` / `didDisconnectNotification`, maintains the last-connected-wins stack, and wires the active controller's handlers to `InputDispatcher`. Hard to unit test (needs real device); validated via the manual checklist in Task 18.

- [ ] **Step 1: Implement ControllerManager**

Run:
```bash
mkdir -p Sources/FooTinderPad/Controller
```

Write `Sources/FooTinderPad/Controller/ControllerManager.swift`:

```swift
import Foundation
import GameController
import os

final class ControllerManager {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "ControllerManager")
    private weak var dispatcher: InputDispatcher?
    private var stack: [GCController] = []
    private(set) var active: GCController?

    /// Called whenever the active controller changes (connect / disconnect / switch).
    var onActiveChanged: ((GCController?) -> Void)?

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(didConnect),
                                               name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didDisconnect),
                                               name: .GCControllerDidDisconnect, object: nil)
        for c in GCController.controllers() { adopt(c) }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        unwireCurrent()
        stack.removeAll()
        active = nil
    }

    @objc private func didConnect(_ note: Notification) {
        guard let c = note.object as? GCController else { return }
        adopt(c)
    }

    @objc private func didDisconnect(_ note: Notification) {
        guard let c = note.object as? GCController else { return }
        stack.removeAll { $0 === c }
        if active === c {
            unwireCurrent()
            active = nil
            if let next = stack.last { switchTo(next) } else { onActiveChanged?(nil) }
        }
    }

    private func adopt(_ c: GCController) {
        guard c.extendedGamepad != nil else {
            log.info("ignoring non-extended controller: \(c.vendorName ?? "?", privacy: .public)")
            return
        }
        if !stack.contains(where: { $0 === c }) { stack.append(c) }
        switchTo(c)
    }

    private func switchTo(_ c: GCController) {
        unwireCurrent()
        active = c
        wire(c)
        onActiveChanged?(c)
    }

    private func unwireCurrent() {
        guard let prev = active, let pad = prev.extendedGamepad else { return }
        // Drop strong-referencing handlers
        let buttons: [GCControllerButtonInput] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.leftShoulder, pad.rightShoulder,
            pad.leftThumbstickButton ?? GCControllerButtonInput(),
            pad.rightThumbstickButton ?? GCControllerButtonInput(),
            pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right,
        ]
        for b in buttons { b.valueChangedHandler = nil }
        pad.leftTrigger.valueChangedHandler = nil
        pad.rightTrigger.valueChangedHandler = nil
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
        dispatcher?.drainHeldInputs()
    }

    private func wire(_ c: GCController) {
        guard let pad = c.extendedGamepad, let dispatcher = dispatcher else { return }

        // Binary buttons
        let map: [(GCControllerButtonInput, ControllerButton)] = [
            (pad.buttonA, .buttonA), (pad.buttonB, .buttonB),
            (pad.buttonX, .buttonX), (pad.buttonY, .buttonY),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown),
            (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
        ]
        for (input, name) in map {
            input.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(name, pressed: pressed)
            }
        }
        if let lts = pad.leftThumbstickButton {
            lts.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(.leftThumbstickButton, pressed: pressed)
            }
        }
        if let rts = pad.rightThumbstickButton {
            rts.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(.rightThumbstickButton, pressed: pressed)
            }
        }

        // Triggers (analog → hysteresis in dispatcher)
        pad.leftTrigger.valueChangedHandler = { [weak dispatcher] _, value, _ in
            dispatcher?.handleTrigger(.leftTrigger, value: Double(value))
        }
        pad.rightTrigger.valueChangedHandler = { [weak dispatcher] _, value, _ in
            dispatcher?.handleTrigger(.rightTrigger, value: Double(value))
        }

        // Sticks (sample only; emission happens in TickLoop)
        pad.leftThumbstick.valueChangedHandler = { [weak dispatcher] _, x, y in
            dispatcher?.updateLeftStick(x: Double(x), y: Double(y))
        }
        pad.rightThumbstick.valueChangedHandler = { [weak dispatcher] _, x, y in
            dispatcher?.updateRightStick(x: Double(x), y: Double(y))
        }
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
swift build
```

Expected: no errors. (`GCControllerButtonInput()` literal init is private — adjust if compiler complains by wrapping the optional thumbstick buttons differently.)

If `GCControllerButtonInput()` is not callable, replace the unwire loop with:

```swift
let buttons: [GCControllerButtonInput?] = [
    pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
    pad.leftShoulder, pad.rightShoulder,
    pad.leftThumbstickButton, pad.rightThumbstickButton,
    pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right,
]
for b in buttons { b?.valueChangedHandler = nil }
```

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/Controller/ControllerManager.swift
git commit -m "feat: ControllerManager with last-connected-wins selection"
```

---

## Task 14: TickLoop

**Files:**
- Create: `Sources/FooTinderPad/Controller/TickLoop.swift`

**Why:** Drives `InputDispatcher.tick(dt:)` at the display refresh rate. CVDisplayLink is not unit-testable; smoke tested in Task 18.

- [ ] **Step 1: Implement TickLoop**

Write `Sources/FooTinderPad/Controller/TickLoop.swift`:

```swift
import Foundation
import CoreVideo
import os

final class TickLoop {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "TickLoop")
    private weak var dispatcher: InputDispatcher?
    private var link: CVDisplayLink?
    private var lastHostTime: UInt64 = 0

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func start() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let l = link else {
            log.error("CVDisplayLinkCreateWithActiveCGDisplays failed")
            return
        }
        self.link = l

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(l, { _, inNow, inOutputTime, _, _, ctx in
            let lp = Unmanaged<TickLoop>.fromOpaque(ctx!).takeUnretainedValue()
            let now = inNow.pointee.hostTime
            DispatchQueue.main.async { lp.tick(hostTime: now) }
            return kCVReturnSuccess
        }, observer)
        CVDisplayLinkStart(l)
    }

    func stop() {
        if let l = link { CVDisplayLinkStop(l) }
        link = nil
    }

    private func tick(hostTime: UInt64) {
        let dt: Double
        if lastHostTime == 0 {
            dt = 1.0 / 60.0
        } else {
            let elapsed = hostTime &- lastHostTime
            // Convert mach host time delta to seconds
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let nanos = elapsed * UInt64(info.numer) / UInt64(info.denom)
            dt = Double(nanos) / 1_000_000_000.0
        }
        lastHostTime = hostTime
        dispatcher?.tick(dt: dt.clamped(to: 1.0/240.0 ... 1.0/30.0))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
swift build
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/Controller/TickLoop.swift
git commit -m "feat: TickLoop driven by CVDisplayLink with bounded dt"
```

---

## Task 15: AccessibilityGate

**Files:**
- Create: `Sources/FooTinderPad/System/AccessibilityGate.swift`

**Why:** Guides the user through granting Accessibility on first launch and tracks state so the menu bar icon can reflect it.

- [ ] **Step 1: Implement AccessibilityGate**

Write `Sources/FooTinderPad/System/AccessibilityGate.swift`:

```swift
import AppKit
import ApplicationServices

final class AccessibilityGate {
    enum State: Equatable { case granted, denied }

    private(set) var state: State
    private var pollTimer: Timer?

    /// Called on the main queue every time `state` transitions.
    var onStateChange: ((State) -> Void)?

    init() {
        self.state = AXIsProcessTrusted() ? .granted : .denied
    }

    /// If denied, shows an alert that links to System Settings and quits the app.
    func checkAndPromptIfNeeded() {
        guard state == .denied else { return }

        let alert = NSAlert()
        alert.messageText = "FooTinderPad needs Accessibility permission"
        alert.informativeText = """
        FooTinderPad relays controller input as mouse and keyboard events.
        macOS requires Accessibility access to do this.

        Grant access in System Settings → Privacy & Security → Accessibility,
        then re-launch FooTinderPad.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        NSApp.terminate(nil)
    }

    /// Starts a 5 s timer that picks up grant changes made while running.
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let newState: State = AXIsProcessTrusted() ? .granted : .denied
            if newState != self.state {
                self.state = newState
                self.onStateChange?(newState)
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
swift build
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/System/AccessibilityGate.swift
git commit -m "feat: AccessibilityGate with onboarding alert and 5s state polling"
```

---

## Task 16: MenuBar (extracted from main.swift)

**Files:**
- Create: `Sources/FooTinderPad/UI/MenuBar.swift`

**Why:** Move and extend the existing menu bar code: status line, Reload Config, Reveal Config, About, Quit, plus icon color reflecting state.

- [ ] **Step 1: Implement MenuBar**

Run:
```bash
mkdir -p Sources/FooTinderPad/UI
```

Write `Sources/FooTinderPad/UI/MenuBar.swift`:

```swift
import AppKit

final class MenuBar {
    private var statusItem: NSStatusItem!
    private var statusLineItem: NSMenuItem!
    private var menu: NSMenu!

    var onReloadConfig: (() -> Void)?
    var onRevealConfig: (() -> Void)?
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    enum IconState { case operational, idle, unauthorized }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.idle)

        menu = NSMenu()
        menu.autoenablesItems = false

        statusLineItem = NSMenuItem(title: "No controller", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload Config", action: #selector(_reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let reveal = NSMenuItem(title: "Reveal Config in Finder", action: #selector(_reveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About FooTinderPad", action: #selector(_about), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(_quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setStatusLine(_ text: String) {
        statusLineItem.title = text
    }

    func setIcon(_ state: IconState) {
        guard let button = statusItem?.button else { return }
        let color: NSColor
        switch state {
        case .operational: color = .white
        case .idle:        color = .gray
        case .unauthorized: color = .systemRed
        }
        let size = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular, scale: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        let cfg = size.applying(palette)
        let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        image?.isTemplate = false
        button.image = image
        button.title = ""
    }

    @objc private func _reload() { onReloadConfig?() }
    @objc private func _reveal() { onRevealConfig?() }
    @objc private func _about() { onAbout?() }
    @objc private func _quit()  { onQuit?() }
}
```

- [ ] **Step 2: Build**

Run:
```bash
swift build
```

Expected: no errors. (Existing `main.swift` still owns the old menu bar code; both will coexist until Task 17 removes the old one.)

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/UI/MenuBar.swift
git commit -m "feat: MenuBar with status line, Reload, Reveal, About, Quit"
```

---

## Task 17: AppDelegate Composition Root + main.swift Trim

**Files:**
- Create: `Sources/FooTinderPad/AppDelegate.swift`
- Modify: `Sources/FooTinderPad/main.swift`

**Why:** Wire `ConfigManager` → `KeySynthesizer` / `MouseSynthesizer` → `InputDispatcher` → `ControllerManager` + `TickLoop`, with `AccessibilityGate` and `MenuBar` for surface. The new `AppDelegate.swift` is the composition root; `main.swift` keeps the existing 4-line bootstrap pattern.

- [ ] **Step 1: Write the new AppDelegate**

Write `Sources/FooTinderPad/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBar()
    private let accessibility = AccessibilityGate()
    private let configManager = ConfigManager()
    private let sink: EventSink = CGEventSink()
    private lazy var key = KeySynthesizer(sink: sink)
    private lazy var mouse = MouseSynthesizer(sink: sink)
    private lazy var dispatcher = InputDispatcher(
        config: { [weak self] in self?.configManager.current ?? .empty },
        key: key,
        mouse: mouse
    )
    private lazy var controllers = ControllerManager(dispatcher: dispatcher)
    private lazy var tickLoop = TickLoop(dispatcher: dispatcher)

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        installMenuBar()

        configManager.onSwap = { [weak self] _ in
            self?.dispatcher.drainHeldInputs()
        }
        configManager.start()

        accessibility.onStateChange = { [weak self] state in
            self?.refreshMenuBarState()
            if state == .denied { self?.dispatcher.drainHeldInputs() }
        }
        accessibility.checkAndPromptIfNeeded() // terminates if denied
        accessibility.startPolling()

        controllers.onActiveChanged = { [weak self] _ in
            self?.refreshMenuBarState()
        }
        controllers.start()
        tickLoop.start()

        refreshMenuBarState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickLoop.stop()
        controllers.stop()
        configManager.stop()
        accessibility.stop()
    }

    // MARK: - menu bar wiring

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    private func installMenuBar() {
        menuBar.install()
        menuBar.onReloadConfig = { [weak self] in self?.configManager.reloadNow() }
        menuBar.onRevealConfig = {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.configURL])
        }
        menuBar.onAbout = { [weak self] in self?.showAboutPanel() }
        menuBar.onQuit  = { NSApp.terminate(nil) }
    }

    private func refreshMenuBarState() {
        switch accessibility.state {
        case .denied:
            menuBar.setIcon(.unauthorized)
            menuBar.setStatusLine("⚠ Accessibility not granted")
        case .granted:
            if let c = controllers.active {
                menuBar.setIcon(.operational)
                menuBar.setStatusLine(c.vendorName ?? "Controller connected")
            } else {
                menuBar.setIcon(.idle)
                menuBar.setStatusLine("No controller")
            }
        }
    }

    private func showAboutPanel() {
        let hash = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String ?? ""
        let date = Bundle.main.object(forInfoDictionaryKey: "GitCommitDate") as? String ?? ""
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        let detail = [hash, date].filter { !$0.isEmpty }.joined(separator: ",")
        if !detail.isEmpty {
            options[.applicationVersion] = detail
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
```

- [ ] **Step 2: Replace `main.swift` with the bootstrap**

Overwrite `Sources/FooTinderPad/main.swift` with:

```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 3: Build and run unit tests**

Run:
```bash
make test
```

Expected: all unit tests pass; the build links the new AppDelegate.

- [ ] **Step 4: Build the app and launch it (no controller required)**

Run:
```bash
make app
open FooTinderPad.app
```

Expected:
- Menu bar shows the icon (gray if Accessibility granted but no controller; red if not granted).
- If Accessibility not granted, an `NSAlert` appears.
- After granting, status line reads `No controller`.
- `~/Library/Application Support/FooTinderPad/config.json` exists.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/AppDelegate.swift Sources/FooTinderPad/main.swift
git commit -m "feat: AppDelegate composition root wires everything together"
```

---

## Task 18: Manual Integration Checklist

**Files:** None to write — this is verification.

**Why:** Confirms the framework-coupled pieces (GameController, CGEvent, CVDisplayLink, AX, DispatchSource) work together against a real device.

- [ ] **Step 1: Rebuild and install the .app**

Run:
```bash
make app
open FooTinderPad.app
```

- [ ] **Step 2: Run each item from the spec's manual checklist**

For each, document outcome in your session notes (or git note `git notes add -m "checklist: ..."`):

  1. Connect Xbox controller; push left stick → cursor moves; release → cursor stops.
  2. Push right stick → page scrolls (vertical and horizontal both work).
  3. Press A → space character appears in a focused text field.
  4. Press RT → Alt+Return fires (in Finder this triggers rename).
  5. Hold LT → RightShift held; combined with letter keys produces uppercase.
  6. Edit `~/Library/Application Support/FooTinderPad/config.json` (e.g. change `mouseSpeed`); save → new value takes effect without restart.
  7. Disconnect Xbox, connect DualSense → DualSense becomes active; reverse order → reverts to Xbox.
  8. Connect both at once → most recently connected wins.
  9. Revoke Accessibility permission while running → menu bar icon turns red within 5 s; no inputs synthesized; no crash.
  10. Edit config to invalid JSON, save → previous config still active; warning visible in Console.app under subsystem `com.purefuncinc.FooTinderPad`.

- [ ] **Step 3: For any failures, file follow-up tasks before declaring done**

For each manual item that fails, write:
- the symptom seen,
- the file/component implicated,
- the proposed fix.

These become new TDD tasks on the next planning pass.

- [ ] **Step 4: If everything passes, tag the milestone**

```bash
git tag -a v0.1.0-controller-bridge -m "controller input bridge v0.1.0 — manual checklist clear"
```

---

## Self-Review

**Spec coverage check:**

| Spec section | Implementing task(s) |
|---|---|
| § 1 Architecture (single-process, threading) | Task 17 (AppDelegate composition); Tasks 14, 11 (display link + dispatch source on main queue) |
| § 1 File layout | Tasks 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 |
| § 2 Sampling (sticks via valueChangedHandler updating state, tick consumes) | Tasks 12 (dispatcher.updateLeftStick / updateRightStick), 13 (wiring), 14 (tick) |
| § 2 Circular deadzone + linear curve + accumulator + tickScale | Task 4 |
| § 2 CGEvent specifics (cghidEventTap, line scroll, mouseMoved) | Task 5 |
| § 3 Naming dictionary (PC + macOS aliases) | Task 3 |
| § 3 Modifier ref-count | Task 6 |
| § 3 Per-binding semantics (key / mouseButton / none / mod-only / Fn flag) | Tasks 6, 7, 12 |
| § 3 Trigger hysteresis | Task 12 |
| § 3 Controller mapping (14 inputs) | Tasks 2, 13 |
| § 4 Path + first-launch seed | Tasks 9, 11 |
| § 4 Schema + Codable + ResolvedConfig | Task 8 |
| § 4 Validation matrix | Task 8 |
| § 4 Hot reload via DispatchSource + debounce + drain | Task 11, plus drain on swap wired in Task 17 |
| § 4 Error matrix | Tasks 8, 11 (load fallback chain) |
| § 5 Launch sequence | Task 17 |
| § 5 Accessibility gate + 5 s polling | Task 15 |
| § 5 Last-connected-wins + drain on switch | Task 13 |
| § 5 TickLoop CVDisplayLink + dt | Task 14 |
| § 5 Menu bar items + icon color states | Tasks 16, 17 |
| § 6 KeyParserTests | Task 3 |
| § 6 StickProcessorTests | Task 4 |
| § 6 ModifierRefCountTests (covered as KeySynthesizerTests) | Task 6 |
| § 6 ConfigParserTests | Task 8 |
| § 6 Manual integration checklist | Task 18 |

**Placeholder scan:** None of `TBD`, `TODO`, `implement later`, vague-handler comments. Each code step shows full code; each command step shows the exact command and expected output.

**Type consistency check:**
- `ParsedKey` defined in Task 3, used identically in Tasks 6 and 12.
- `ResolvedBinding` defined in Task 8, consumed identically in Task 12 (`applyBinding` switch matches).
- `EventSink` protocol signature defined in Task 5, implemented by `CGEventSink` (Task 5) and `RecordingSink` (Task 5), depended on by `KeySynthesizer` (Task 6) and `MouseSynthesizer` (Task 7) — matches.
- `StickProcessor.tick(x:y:speed:tickScale:invertY:)` signature consistent across Task 4 (definition + tests) and Task 12 (caller).
- `ControllerButton` raw values match the `Config.bindings` JSON keys in Task 8 and the wiring map in Task 13.
- `ResolvedConfig.empty` defined in Task 11, referenced by Task 17 default closure — consistent.

No issues found. Plan is self-consistent.
