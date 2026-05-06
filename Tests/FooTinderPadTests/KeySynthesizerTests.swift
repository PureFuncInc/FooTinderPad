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
            .keyEvent(CGKeyCode(kVK_Space), true, [], false),
            .keyEvent(CGKeyCode(kVK_Space), false, [], false),
        ])
    }

    func testComboEmitsModThenMainOnPressAndReverseOnRelease() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        let combo = ParsedKey(mainKey: CGKeyCode(kVK_Return), modifiers: [.leftAlt])

        synth.press(combo)
        synth.release(combo)

        XCTAssertEqual(sink.actions, [
            .keyEvent(CGKeyCode(kVK_Option), true, .maskAlternate, false),
            .keyEvent(CGKeyCode(kVK_Return), true, .maskAlternate, false),
            .keyEvent(CGKeyCode(kVK_Return), false, .maskAlternate, false),
            .keyEvent(CGKeyCode(kVK_Option), false, [], false),
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
        let altDowns = sink.actions.filter { $0 == .keyEvent(altKeyCode, true, .maskAlternate, false) }
        let altUps   = sink.actions.filter {
            if case let .keyEvent(c, down, _, _) = $0 { return c == altKeyCode && down == false }
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
            .keyEvent(CGKeyCode(kVK_RightShift), true, .maskShift, false),
            .keyEvent(CGKeyCode(kVK_RightShift), false, [], false),
        ])
    }

    func testUnderflowReleaseIsNoOp() {
        let sink = RecordingSink()
        let synth = KeySynthesizer(sink: sink)
        let altReturn = ParsedKey(mainKey: CGKeyCode(kVK_Return), modifiers: [.leftAlt])

        // Release without prior press: must not crash, must emit no Alt keyUp
        synth.release(altReturn)
        let altUps = sink.actions.contains { action in
            if case let .keyEvent(_, down, _, _) = action { return down == false }
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
            .keyEvent(CGKeyCode(kVK_UpArrow), true, .maskSecondaryFn, false),
            .keyEvent(CGKeyCode(kVK_UpArrow), false, .maskSecondaryFn, false),
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
            if case let .keyEvent(c, down, _, _) = action { return (c, down) }
            return nil
        }
        XCTAssertTrue(names.contains(where: { $0 == (returnKeyCode, false) }))
        XCTAssertTrue(names.contains(where: { $0 == (altKeyCode, false) }))
    }
}
