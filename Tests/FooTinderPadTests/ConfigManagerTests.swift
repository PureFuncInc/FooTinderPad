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
