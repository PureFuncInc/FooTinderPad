import XCTest
import CoreGraphics
@testable import FooTinderPad

final class CGEventSinkClampTests: XCTestCase {
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testInsideDisplayReturnsPointUnchanged() {
        let p = CGPoint(x: 100, y: 200)
        XCTAssertEqual(CGEventSink.clamp(target: p, displays: [mainDisplay]), p)
    }

    func testClampsPastRightEdge() {
        let result = CGEventSink.clamp(target: CGPoint(x: 5000, y: 540), displays: [mainDisplay])
        XCTAssertEqual(result, CGPoint(x: 1919, y: 540))
    }

    func testClampsPastLeftEdge() {
        let result = CGEventSink.clamp(target: CGPoint(x: -100, y: 540), displays: [mainDisplay])
        XCTAssertEqual(result, CGPoint(x: 0, y: 540))
    }

    func testClampsPastTopEdge() {
        let result = CGEventSink.clamp(target: CGPoint(x: 800, y: -50), displays: [mainDisplay])
        XCTAssertEqual(result, CGPoint(x: 800, y: 0))
    }

    func testClampsPastBottomEdge() {
        let result = CGEventSink.clamp(target: CGPoint(x: 800, y: 5000), displays: [mainDisplay])
        XCTAssertEqual(result, CGPoint(x: 800, y: 1079))
    }

    func testClampsBothAxesWhenOffCorner() {
        let result = CGEventSink.clamp(target: CGPoint(x: -50, y: -50), displays: [mainDisplay])
        XCTAssertEqual(result, CGPoint(x: 0, y: 0))
    }

    func testPointInsideSecondaryDisplayPassesThrough() {
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let p = CGPoint(x: 3000, y: 500)
        let result = CGEventSink.clamp(target: p, displays: [mainDisplay, secondary])
        XCTAssertEqual(result, p)
    }

    func testPointInGapBetweenDisplaysClampsToNearestEdge() {
        // Two displays with a horizontal gap from x=1920 to x=2200.
        let secondary = CGRect(x: 2200, y: 0, width: 1280, height: 720)
        // Point at x=1950 is closer to mainDisplay's right edge.
        let nearMain = CGEventSink.clamp(target: CGPoint(x: 1950, y: 500), displays: [mainDisplay, secondary])
        XCTAssertEqual(nearMain, CGPoint(x: 1919, y: 500))
        // Point at x=2150 is closer to secondary's left edge.
        let nearSecondary = CGEventSink.clamp(target: CGPoint(x: 2150, y: 500), displays: [mainDisplay, secondary])
        XCTAssertEqual(nearSecondary, CGPoint(x: 2200, y: 500))
    }

    func testEmptyDisplaysReturnsPointUnchanged() {
        let p = CGPoint(x: 9999, y: -42)
        XCTAssertEqual(CGEventSink.clamp(target: p, displays: []), p)
    }
}
