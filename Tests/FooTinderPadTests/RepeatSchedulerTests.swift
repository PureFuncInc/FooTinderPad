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

    func testFrameDropCoalescesToSingleEmit() {
        // A long-skipped tick must emit exactly once, not N times.
        // lastEmitTime advances on emit so missed ticks do not "owe" extra events.
        let scheduler = RepeatScheduler()
        var emits = 0
        scheduler.start(button: .buttonX, parsedKey: backspace, now: 0)

        scheduler.tick(now: 0.400) { _, _ in emits += 1 }   // 1
        // Skip ~5 seconds — at 33 ms interval that would owe ~140 emits if buggy.
        scheduler.tick(now: 5.000) { _, _ in emits += 1 }   // 2 (single emit, not 140)
        XCTAssertEqual(emits, 2)

        // Next tick paced by interval from the catch-up emit.
        scheduler.tick(now: 5.034) { _, _ in emits += 1 }   // 3
        XCTAssertEqual(emits, 3)
    }
}
