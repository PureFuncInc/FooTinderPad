import XCTest
@testable import FooTinderPad

final class DualSenseBatteryReaderTests: XCTestCase {

    /// Build a 78-byte buffer with bytes[0]=0x31 (realistic header — parser
    /// shouldn't depend on it) and bytes[54] set to the test's input.
    private func report(byte54: UInt8) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 78)
        buf[0] = 0x31
        buf[54] = byte54
        return buf
    }

    // MARK: - Discharging (state nibble == 0)

    func testParseDischargingMidLevel() {
        // 0x07 → high=0 (discharging), low=7 → 70%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x07))
        XCTAssertEqual(s, .discharging(level: 70))
        XCTAssertFalse(s.isLow)
    }

    func testParseDischargingLow() {
        // 0x02 → discharging, 20%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x02))
        XCTAssertEqual(s, .discharging(level: 20))
        XCTAssertTrue(s.isLow, "20% is at the inclusive low threshold")
    }

    func testParseDischargingZero() {
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x00))
        XCTAssertEqual(s, .discharging(level: 0))
        XCTAssertTrue(s.isLow)
    }

    // MARK: - Charging (state nibble == 1)

    func testParseChargingMid() {
        // 0x15 → high=1 (charging), low=5 → 50%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x15))
        XCTAssertEqual(s, .charging(level: 50))
        XCTAssertFalse(s.isLow, "charging suppresses isLow")
    }

    func testParseChargingLowNibbleStaysCharging() {
        // 0x12 → charging at 20% — isLow must NOT trigger
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x12))
        XCTAssertEqual(s, .charging(level: 20))
        XCTAssertFalse(s.isLow)
    }

    func testParseChargingFullCollapsesToFull() {
        // 0x1A → high=1, low=10 → would be charging at 100%, but collapses to .full
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x1A))
        XCTAssertEqual(s, .full)
    }

    // MARK: - Full (state nibble == 2)

    func testParseFullState() {
        // 0x2A → high=2 (full), low=10
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x2A))
        XCTAssertEqual(s, .full)
    }

    func testParseFullStateLowNibbleIgnored() {
        // 0x20 → high=2 (full), low=0 — state wins regardless of level
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x20))
        XCTAssertEqual(s, .full)
    }

    // MARK: - Unknown / clamping / malformed

    func testParseUnknownStateNibble() {
        // 0x37 → high=3, undocumented — returns .none rather than misrender
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x37))
        XCTAssertEqual(s, .none)
    }

    func testParseLevelOverflowClamped() {
        // 0x0F → high=0 (discharging), low=15 (out of documented 0..10 range) — clamped to 10 → 100%
        let s = DualSenseBatteryReader.parse(report: report(byte54: 0x0F))
        XCTAssertEqual(s, .discharging(level: 100))
    }

    func testParseShortReportReturnsNone() {
        // Buffer too short to reach byte 54
        let buf = [UInt8](repeating: 0, count: 30)
        XCTAssertEqual(DualSenseBatteryReader.parse(report: buf), .none)
    }

    func testParseEmptyReportReturnsNone() {
        XCTAssertEqual(DualSenseBatteryReader.parse(report: []), .none)
    }
}
