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
