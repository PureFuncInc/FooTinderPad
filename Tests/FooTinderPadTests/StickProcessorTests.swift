import XCTest
@testable import FooTinderPad

final class StickProcessorTests: XCTestCase {

    func testCircularDeadzoneSuppressesSmallVector() {
        var p = StickProcessor(deadzone: 0.15)
        let out = p.tick(x: 0.1, y: 0.1, speed: 15, curve: 1.0, tickScale: 1, invertY: true)
        XCTAssertEqual(out.deltaX, 0)
        XCTAssertEqual(out.deltaY, 0)
    }

    func testFullDeflectionEmitsFullSpeed() {
        var p = StickProcessor(deadzone: 0.15)
        let out = p.tick(x: 1.0, y: 0.0, speed: 15, curve: 1.0, tickScale: 1, invertY: true)
        XCTAssertEqual(out.deltaX, 15)
        XCTAssertEqual(out.deltaY, 0)
    }

    func testFractionalAccumulatorAccumulatesAcrossTicks() {
        var p = StickProcessor(deadzone: 0)
        // 10 ticks at "0.4 px/tick" total. Use small speed to force fractional.
        var totalX = 0
        for _ in 0..<10 {
            let out = p.tick(x: 0.4 / 15.0, y: 0, speed: 15, curve: 1.0, tickScale: 1, invertY: true)
            totalX += out.deltaX
        }
        XCTAssertEqual(totalX, 4)
    }

    func testEnteringDeadzoneResetsAccumulator() {
        var p = StickProcessor(deadzone: 0.15)
        // Build up accumulator just under whole pixel
        _ = p.tick(x: 0.05, y: 0, speed: 1, curve: 1.0, tickScale: 1, invertY: true) // skipped (in deadzone)
        let after = p.tick(x: 0, y: 0, speed: 1, curve: 1.0, tickScale: 1, invertY: true)
        XCTAssertEqual(after.deltaX, 0)
    }

    func testYAxisInvertedForMouseMode() {
        var p = StickProcessor(deadzone: 0)
        let out = p.tick(x: 0, y: 1.0, speed: 15, curve: 1.0, tickScale: 1, invertY: true)
        XCTAssertEqual(out.deltaY, -15)
    }

    func testYAxisNotInvertedForScrollMode() {
        var p = StickProcessor(deadzone: 0)
        let out = p.tick(x: 0, y: 1.0, speed: 5, curve: 1.0, tickScale: 1, invertY: false)
        XCTAssertEqual(out.deltaY, 5)
    }

    func testTickScaleScalesEmittedDelta() {
        var p120 = StickProcessor(deadzone: 0)
        let half = p120.tick(x: 1, y: 0, speed: 30, curve: 1.0, tickScale: 0.5, invertY: true)
        XCTAssertEqual(half.deltaX, 15)

        var p60 = StickProcessor(deadzone: 0)
        let full = p60.tick(x: 1, y: 0, speed: 30, curve: 1.0, tickScale: 1.0, invertY: true)
        XCTAssertEqual(full.deltaX, 30)
    }

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
    // Use deadzone=0 and x=0.5 so n=0.5 exactly (no FP drift).
    // pow(0.5, 2) = 0.25 → per-tick contribution 0.25 * 100 = 25.
    func testCurveTwoCompressesMidRange() {
        var p = StickProcessor(deadzone: 0)
        var total = 0
        for _ in 0..<100 {
            let out = p.tick(x: 0.5, y: 0.0, speed: 100, curve: 2.0,
                             tickScale: 1, invertY: true)
            total += out.deltaX
        }
        // 100 ticks * 0.25 * 100 = 2500
        XCTAssertEqual(total, 2500)
    }

    // And with curve=1.0 the same input is linear: per-tick contribution
    // 0.5 * 100 = 50, over 100 ticks → 5000.
    func testCurveOneMidRangeIsLinear() {
        var p = StickProcessor(deadzone: 0)
        var total = 0
        for _ in 0..<100 {
            let out = p.tick(x: 0.5, y: 0.0, speed: 100, curve: 1.0,
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
}
