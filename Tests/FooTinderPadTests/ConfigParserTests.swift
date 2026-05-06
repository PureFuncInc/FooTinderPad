import XCTest
@testable import FooTinderPad

final class ConfigParserTests: XCTestCase {

    func testParsesDefaultConfigCompletely() throws {
        let json = """
        {
          "deadzone": 0.15,
          "mouseSpeed": 15,
          "scrollSpeed": 5,
          "leftStick": "mouse",
          "rightStick": "scroll",
          "bindings": {
            "buttonA": { "type": "key", "key": "Space" },
            "buttonB": { "type": "key", "key": "Return" },
            "buttonX": { "type": "mouseButton", "button": "left" },
            "buttonY": { "type": "key", "key": "Backspace" },
            "leftShoulder": { "type": "key", "key": "Escape" },
            "rightShoulder": { "type": "mouseButton", "button": "right" },
            "leftTrigger": { "type": "key", "key": "RightShift" },
            "rightTrigger": { "type": "key", "key": "Alt+Return" },
            "leftThumbstickButton": { "type": "none" },
            "rightThumbstickButton": { "type": "none" },
            "dpadUp": { "type": "key", "key": "Up" },
            "dpadDown": { "type": "key", "key": "Down" },
            "dpadLeft": { "type": "key", "key": "Left" },
            "dpadRight": { "type": "key", "key": "Right" }
          }
        }
        """.data(using: .utf8)!

        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.15)
        XCTAssertEqual(result.config.mouseSpeed, 15)
        XCTAssertEqual(result.config.scrollSpeed, 5)
        XCTAssertEqual(result.config.leftStick, .mouse)
        XCTAssertEqual(result.config.rightStick, .scroll)
        XCTAssertEqual(result.config.bindings.count, 16)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMissingFieldsUseDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.15)
        XCTAssertEqual(result.config.mouseSpeed, 15)
        XCTAssertEqual(result.config.scrollSpeed, 5)
        XCTAssertEqual(result.config.leftStick, .mouse)
        XCTAssertEqual(result.config.rightStick, .scroll)
    }

    func testNegativeDeadzoneIsClampedWithWarning() throws {
        let json = #"{"deadzone": -0.1}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.0)
        XCTAssertTrue(result.warnings.contains { $0.contains("deadzone") })
    }

    func testTooLargeDeadzoneIsClampedWithWarning() throws {
        let json = #"{"deadzone": 0.8}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.deadzone, 0.49)
        XCTAssertTrue(result.warnings.contains { $0.contains("deadzone") })
    }

    func testZeroMouseSpeedFallsBackToDefault() throws {
        let json = #"{"mouseSpeed": 0}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.mouseSpeed, 15)
        XCTAssertTrue(result.warnings.contains { $0.contains("mouseSpeed") })
    }

    func testUnknownButtonNameIsDropped() throws {
        let json = #"""
        { "bindings": { "buttonZ": { "type": "key", "key": "Space" } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA], ResolvedBinding.none)
        XCTAssertTrue(result.warnings.contains { $0.contains("buttonZ") })
    }

    func testUnparsableKeyBecomesNoneWithWarning() throws {
        let json = #"""
        { "bindings": { "buttonA": { "type": "key", "key": "Foo" } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA], ResolvedBinding.none)
        XCTAssertTrue(result.warnings.contains { $0.contains("buttonA") })
    }

    func testPartialBindingsFillRestWithNone() throws {
        let json = #"""
        { "bindings": { "buttonA": { "type": "key", "key": "Space" } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA], .key(mainKey: 0x31, modifiers: []))
        XCTAssertEqual(result.config.bindings[.buttonB], ResolvedBinding.none)
        XCTAssertEqual(result.config.bindings.count, ControllerButton.allCases.count)
    }

}
