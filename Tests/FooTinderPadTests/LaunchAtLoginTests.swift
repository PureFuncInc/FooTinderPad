import XCTest
@testable import FooTinderPad

final class LaunchAtLoginTests: XCTestCase {
    func testActionWhenDisabled() {
        XCTAssertEqual(LaunchAtLogin.action(for: .disabled), .enable)
    }

    func testActionWhenEnabled() {
        XCTAssertEqual(LaunchAtLogin.action(for: .enabled), .disable)
    }

    func testActionWhenRequiresApproval() {
        XCTAssertEqual(LaunchAtLogin.action(for: .requiresApproval), .openSystemSettings)
    }

    func testActionWhenFailed() {
        XCTAssertEqual(LaunchAtLogin.action(for: .failed("any error")), .openSystemSettings)
    }
}
