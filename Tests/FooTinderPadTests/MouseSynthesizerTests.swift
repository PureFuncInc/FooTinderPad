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
