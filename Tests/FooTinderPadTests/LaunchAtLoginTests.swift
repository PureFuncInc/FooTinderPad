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

import Foundation

extension LaunchAtLoginTests {
    private func tempPlistURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftp-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("com.purefuncinc.FooTinderPad.plist")
    }

    func testReadStateWhenPlistExistsReturnsEnabled() throws {
        let url = tempPlistURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Write any non-empty file; readState() only checks existence.
        try Data("placeholder".utf8).write(to: url)

        let lal = LaunchAtLogin(plistURL: url)
        XCTAssertEqual(lal.state, .enabled)
    }

    func testReadStateWhenPlistAbsentDoesNotCrash() {
        // We don't assert exact value — depends on real SMAppService.mainApp.status on this
        // machine — but we DO assert init doesn't throw and returns a valid LaunchAtLoginState.
        let url = tempPlistURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let lal = LaunchAtLogin(plistURL: url)
        // Just touch the property to ensure it was set:
        _ = lal.state
    }

    func testWritePlistEmitsExpectedKeys() throws {
        let url = tempPlistURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try LaunchAtLogin.writePlist(at: url, executablePath: "/Applications/FooTinderPad.app/Contents/MacOS/FooTinderPad")

        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(parsed?["Label"] as? String, "com.purefuncinc.FooTinderPad")
        XCTAssertEqual(parsed?["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(parsed?["KeepAlive"] as? Bool, false)
        XCTAssertEqual(parsed?["ProgramArguments"] as? [String], ["/Applications/FooTinderPad.app/Contents/MacOS/FooTinderPad"])
    }

    func testRemovePlistIsIdempotentWhenAbsent() throws {
        let url = tempPlistURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Plist deliberately not created. removePlist should be a no-op (no throw).
        XCTAssertNoThrow(try LaunchAtLogin.removePlistIfPresent(at: url))
    }
}
