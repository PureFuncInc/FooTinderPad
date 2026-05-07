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
