import XCTest
import GameController
@testable import FooTinderPad

final class BatteryMonitorTests: XCTestCase {

    // MARK: - Discharging

    func testDischargingMidLevel() {
        let s = BatteryMonitor.suffix(level: 0.82, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 82))
        XCTAssertFalse(s.isLow)
    }

    func testDischargingLowLevel() {
        let s = BatteryMonitor.suffix(level: 0.15, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 15))
        XCTAssertTrue(s.isLow)
    }

    func testDischargingExactlyAtThreshold() {
        let s = BatteryMonitor.suffix(level: 0.20, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 20))
        XCTAssertTrue(s.isLow, "threshold is inclusive — 20% is low")
    }

    func testDischargingJustAboveThreshold() {
        let s = BatteryMonitor.suffix(level: 0.21, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 21))
        XCTAssertFalse(s.isLow)
    }

    // MARK: - Charging

    func testChargingNotFull() {
        let s = BatteryMonitor.suffix(level: 0.50, state: .charging)
        XCTAssertEqual(s, .charging(level: 50))
        XCTAssertFalse(s.isLow)
    }

    func testChargingLowIsNotIsLow() {
        // Red is suppressed while charging — the user is already taking action.
        let s = BatteryMonitor.suffix(level: 0.10, state: .charging)
        XCTAssertEqual(s, .charging(level: 10))
        XCTAssertFalse(s.isLow)
    }

    func testChargingAtFullCollapsesToFull() {
        let s = BatteryMonitor.suffix(level: 1.0, state: .charging)
        XCTAssertEqual(s, .full)
    }

    // MARK: - Full + Unknown

    func testFullState() {
        let s = BatteryMonitor.suffix(level: 1.0, state: .full)
        XCTAssertEqual(s, .full)
    }

    func testUnknownStateAlwaysNone() {
        let s = BatteryMonitor.suffix(level: 0.5, state: .unknown)
        XCTAssertEqual(s, .none)
    }

    // MARK: - Clamping

    func testNegativeLevelClamped() {
        let s = BatteryMonitor.suffix(level: -0.1, state: .discharging)
        XCTAssertEqual(s, .discharging(level: 0))
    }

    func testOverflowLevelClamped() {
        let s = BatteryMonitor.suffix(level: 1.5, state: .charging)
        XCTAssertEqual(s, .full)
    }
}
