import XCTest
@testable import FooTinderPad

final class XboxBatteryReaderTests: XCTestCase {
    func testParseBatteryLevel() {
        XCTAssertEqual(XboxBatteryReader.parseBatteryLevel(Data([82])), .discharging(level: 82))
    }

    func testParseBatteryLevelClampsOverflow() {
        XCTAssertEqual(XboxBatteryReader.parseBatteryLevel(Data([255])), .discharging(level: 100))
    }

    func testParseMissingBatteryLevel() {
        XCTAssertEqual(XboxBatteryReader.parseBatteryLevel(nil), .none)
        XCTAssertEqual(XboxBatteryReader.parseBatteryLevel(Data()), .none)
    }
}
