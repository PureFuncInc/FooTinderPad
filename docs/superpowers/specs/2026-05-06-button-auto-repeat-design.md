# Button Auto-Repeat — Design

## Goal

Hold a controller button → the bound key keeps firing at a steady cadence (analogous to holding Backspace or an arrow key on a real keyboard). Today, every button press emits exactly one `keyDown` and one `keyUp` regardless of how long the button is held, so holding ■ Square (Backspace) deletes only one character.

## Scope

- **In scope**: `.key` bindings (with main key, optionally with modifiers).
- **Out of scope**: `.mouseButton` bindings (rapid-fire is a different feature), modifier-only `.key` bindings (no main key to re-emit).

## User-facing model

Auto-repeat is **opt-in per binding** via a new `repeat` field:

```jsonc
"buttonX": { "type": "key", "key": "Backspace", "repeat": true }
```

- Default for missing/null `repeat`: **false** (safe default — accidental repeat on `Cmd+C` etc. is the worst failure mode).
- Repeat timing is **hardcoded** (not yet config-exposed): **400 ms initial delay**, **33 ms interval** (≈30 Hz). Matches typical keyboard repeat feel.
- `repeat: true` on a non-key binding (`mouseButton`, `none`) or on a modifier-only key binding (no main key) → parser warning, treated as `repeat: false`.

## Architecture

Repeat is driven by the existing `TickLoop` (~60 Hz), not separate timers. This avoids timer lifecycle bugs (forgotten cancellations leaving "ghost" repeats), and 33 ms granularity is fine at a 16.67 ms tick.

Per-button state lives in a new `RepeatScheduler` composed into `InputDispatcher`. The state is just `[ControllerButton: Entry]` where `Entry = (parsedKey, pressTime, lastEmitTime)`.

```
button press
  → InputDispatcher.applyBinding
      → KeySynthesizer.press()                      // first keyDown (existing)
      → if .key + repeat: RepeatScheduler.start()   // record press time

every TickLoop tick:
  → RepeatScheduler.tick(now)
      for each held repeating entry:
        if now - pressTime > 400 ms AND now - lastEmitTime > 33 ms:
          KeySynthesizer.repeatPress(parsedKey)     // re-emit main key only
          entry.lastEmitTime = now

button release
  → InputDispatcher.applyBinding
      → RepeatScheduler.stop(button)
      → KeySynthesizer.release()                    // keyUp (existing)

drainHeldInputs (config swap / controller switch):
  → RepeatScheduler.clear()
  → KeySynthesizer.drain()
```

### Why a separate `repeatPress` on KeySynthesizer

Calling `press(parsedKey)` again would re-`acquire` modifiers and bump their reference counts, leaving them stuck after release. The new method only re-emits the main key's `keyDown` with the existing modifier flag set; modifiers stay acquired from the original press.

```swift
func repeatPress(_ k: ParsedKey) {
    guard let main = k.mainKey else { return }
    sink.keyEvent(keyCode: main, down: true, flags: currentFlags(), autorepeat: true)
}
```

The `autorepeat: true` adds a CGEvent integer field (`kCGKeyboardEventAutorepeat`) so the receiving app sees `NSEvent.isARepeat == true` — matches OS convention and lets text editors optimize repeat handling.

### Clock source

`InputDispatcher` holds a `clock: () -> TimeInterval` (default `{ Date().timeIntervalSinceReferenceDate }`). `InputDispatcher.tick(dt:)` calls `repeater.tick(now: clock())`. Tests inject a fake clock that advances manually; production uses wall-clock time. Monotonic vs wall-clock distinction doesn't matter at this scale (button hold durations are well under any plausible NTP step).

## Schema changes

`RawBinding` adds an optional `repeat`:

```swift
private struct RawBinding: Decodable {
    let type: String
    let key: String?
    let button: MouseButton?
    let `repeat`: Bool?
}
```

`ResolvedBinding.key` adds a stored `repeat: Bool`:

```swift
case key(mainKey: CGKeyCode?, modifiers: [ModifierKey], repeat: Bool)
```

`ConfigLoader.load` populates it:

- `repeat == true && mainKey == nil` → warning `"<button>: 'repeat' ignored on modifier-only binding"`, store with `repeat: false`.
- `repeat == true` on `mouseButton` / `none` → warning, no field exists in those cases anyway.

## New / modified files

| File | Change |
|---|---|
| `Sources/FooTinderPad/Input/RepeatScheduler.swift` | **NEW** — small class (~50 lines) with `start / stop / clear / tick`. Emit done via injected closure for testability. |
| `Sources/FooTinderPad/Config/Config.swift` | Add `repeat` to `RawBinding` + `ResolvedBinding.key`; warn on misuse in `ConfigLoader.load`. |
| `Sources/FooTinderPad/Input/KeySynthesizer.swift` | Add `repeatPress(_ k:)`. |
| `Sources/FooTinderPad/Input/EventSink.swift` | Extend `keyEvent` signature to `keyEvent(keyCode:, down:, flags:, autorepeat: Bool = false)`. The default keeps existing call sites unchanged. `CGEventSink.keyEvent` sets `kCGKeyboardEventAutorepeat` via `setIntegerValueField` when `autorepeat == true`. |
| `Sources/FooTinderPad/Input/InputDispatcher.swift` | Hold a `RepeatScheduler`; wire it into `applyBinding`, `tick`, `drainHeldInputs`. |
| `Tests/FooTinderPadTests/ConfigParserTests.swift` | Tests for parsing `repeat`; warning paths. |
| `Tests/FooTinderPadTests/RepeatSchedulerTests.swift` | **NEW** — fake-clock unit tests covering initial delay, interval, stop, clear, multi-button. |
| `~/Library/Application Support/FooTinderPad/config.json` | Add `"repeat": true` on `dpadUp/Down/Left/Right` and `buttonX` (Backspace). |
| `docs/examples/easy-preset.json` | Same. |
| `README.md` | Document the `repeat` field + which preset bindings use it. |

`Resources/DefaultConfig.json` and `Sources/.../Config/DefaultConfig.swift` are not changed — defaults stay non-repeating.

## Edge cases

1. **`repeat: true` on modifier-only binding** (e.g., `"key": "LeftShift"`) → warning, ignored. Modifiers are held continuously by ref-counting; "repeat" makes no sense.
2. **`repeat: true` on `mouseButton`** → warning at parse time. (Not encodable in `ResolvedBinding.mouseButton` either way.)
3. **Multiple repeating buttons held simultaneously** → independent entries in the scheduler, independent timing.
4. **Config hot-reload mid-hold** → `drainHeldInputs` already clears the synthesizer; we add `RepeatScheduler.clear()` to the same path.
5. **Controller disconnects while a button is held** → same drain path triggers in `unwireCurrent`.
6. **Frame drop / tick skip** → next tick catches up; `lastEmitTime` only advances on actual emit, so missed ticks emit on the next tick rather than "owing" multiple events at once.

## Tests

`RepeatSchedulerTests` (new), using fake `Clock` and emit closure:

- `testNoEmitBeforeInitialDelay` — at t=200 ms, no emit.
- `testFirstRepeatAtInitialDelay` — at t=400 ms, one emit.
- `testIntervalAfterInitialDelay` — at t=433 ms, second emit; at t=466 ms, third.
- `testStopHaltsRepeat` — after `stop()`, no further emits.
- `testClearHaltsAll` — `clear()` removes all entries.
- `testIndependentTimingPerButton` — two buttons started at different times each have correct timing.

`ConfigParserTests` additions:

- `testRepeatTrueParses` — `"repeat": true` on key with main key → `.key(_, _, repeat: true)`.
- `testRepeatDefaultsToFalse` — missing field → `repeat: false`.
- `testRepeatIgnoredOnModifierOnly` — `"key": "Shift"` + `"repeat": true` → warning + `repeat: false`.

## Out of scope (future)

- Configurable repeat delay/interval (could be added as `repeatDelay` / `repeatInterval` top-level fields if anyone wants).
- Mouse-button rapid fire — separate feature with different design (it's clicks, not held keys).
- Per-binding rate override.
