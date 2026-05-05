import XCTest
@testable import FooTinderPad

final class ConfigManagerTests: XCTestCase {

    func testLoadFromDataFallbackChain() throws {
        // Direct loadOnce path is the unit being tested here; full filesystem
        // hot-reload is exercised in testReloadsOnFileWrite.
        let mgr = ConfigManager(configURLOverride: URL(fileURLWithPath: "/nonexistent/path/abcdef.json"))
        let result = mgr.loadOnce()
        XCTAssertEqual(result.config.deadzone, 0.15)
        XCTAssertEqual(result.config.bindings.count, ControllerButton.allCases.count)
    }

    func testInvalidJSONOnReloadKeepsPreviousConfig() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        try #"{"mouseSpeed": 33}"#.write(to: url, atomically: true, encoding: .utf8)
        let mgr = ConfigManager(configURLOverride: url)
        mgr.start()
        XCTAssertEqual(mgr.current.mouseSpeed, 33)

        var warningBatches: [[String]] = []
        mgr.onWarnings = { warningBatches.append($0) }

        // Write invalid JSON — performReload should keep previous current.
        try "{ this is not valid json".write(to: url, atomically: true, encoding: .utf8)

        // Wait for DispatchSource → debounce → performReload to run
        let exp = expectation(description: "warning emitted within 2s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if !warningBatches.isEmpty { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.5)

        XCTAssertEqual(mgr.current.mouseSpeed, 33, "previous config must be preserved on parse error")
        XCTAssertTrue(warningBatches.flatMap { $0 }.contains { $0.contains("reload failed") })

        mgr.stop()
    }

    func testReloadsOnFileWrite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ftp-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        let initial = #"{"mouseSpeed": 10}"#
        try initial.write(to: url, atomically: true, encoding: .utf8)

        let mgr = ConfigManager(configURLOverride: url)
        var swaps: [Double] = []
        mgr.onSwap = { cfg in swaps.append(cfg.mouseSpeed) }

        mgr.start()
        XCTAssertEqual(mgr.current.mouseSpeed, 10)

        // Trigger a write that the DispatchSource will pick up
        let updated = #"{"mouseSpeed": 42}"#
        try updated.write(to: url, atomically: true, encoding: .utf8)

        let exp = expectation(description: "swap fires within 1s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if mgr.current.mouseSpeed == 42 { exp.fulfill() }
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(mgr.current.mouseSpeed, 42)
        XCTAssertTrue(swaps.contains(42))

        mgr.stop()
    }
}
