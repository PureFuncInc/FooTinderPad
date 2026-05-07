import XCTest
import Carbon.HIToolbox
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
        XCTAssertEqual(result.config.dpad, .bindings)
        XCTAssertEqual(result.config.dpadMouseSpeed, 3)
        XCTAssertEqual(result.config.dpadScrollSpeed, 2)
        XCTAssertEqual(result.config.bindings.count, 17)
        XCTAssertEqual(result.config.touchpad, .none)
        XCTAssertEqual(result.config.touchpadMouseSpeed, 300)
        XCTAssertEqual(result.config.touchpadScrollSpeed, 20)
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
        XCTAssertEqual(result.config.dpad, .bindings)
    }

    func testTouchpadFieldsHaveDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpad, .none)
        XCTAssertEqual(result.config.touchpadMouseSpeed, 300)
        XCTAssertEqual(result.config.touchpadScrollSpeed, 20)
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

    func testDPadMouseSettingsParse() throws {
        let json = #"""
        {
          "dpad": "mouse",
          "dpadMouseSpeed": 2.5
        }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.dpad, .mouse)
        XCTAssertEqual(result.config.dpadMouseSpeed, 2.5)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testInvalidDPadMouseSpeedFallsBackToDefaultWithWarning() throws {
        let json = #"{"dpadMouseSpeed": 0}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.dpadMouseSpeed, 3)
        XCTAssertTrue(result.warnings.contains { $0.contains("dpadMouseSpeed") })
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
        XCTAssertEqual(result.config.bindings[.buttonA], .key(mainKey: 0x31, modifiers: [], repeat: false))
        XCTAssertEqual(result.config.bindings[.buttonB], ResolvedBinding.none)
        XCTAssertEqual(result.config.bindings.count, ControllerButton.allCases.count)
    }

    func testRepeatTrueParses() throws {
        let json = #"""
        { "bindings": { "buttonA": { "type": "key", "key": "Backspace", "repeat": true } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA],
                       .key(mainKey: CGKeyCode(kVK_Delete), modifiers: [], repeat: true))
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testRepeatDefaultsToFalseWhenMissing() throws {
        let json = #"""
        { "bindings": { "buttonA": { "type": "key", "key": "Space" } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA],
                       .key(mainKey: CGKeyCode(kVK_Space), modifiers: [], repeat: false))
    }

    func testRepeatTrueOnModifierOnlyIsIgnoredWithWarning() throws {
        let json = #"""
        { "bindings": { "buttonA": { "type": "key", "key": "LeftShift", "repeat": true } } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        if case let .key(_, _, isRepeat) = result.config.bindings[.buttonA]! {
            XCTAssertFalse(isRepeat, "repeat must be ignored on modifier-only binding")
        } else {
            XCTFail("expected .key binding")
        }
        XCTAssertTrue(result.warnings.contains { $0.contains("repeat") && $0.contains("buttonA") })
    }

    func testRepeatTrueOnNonKeyBindingsIsIgnoredWithWarning() throws {
        let json = #"""
        { "bindings": {
            "buttonA": { "type": "none", "repeat": true },
            "buttonB": { "type": "mouseButton", "button": "left", "repeat": true }
        } }
        """#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.bindings[.buttonA], ResolvedBinding.none)
        XCTAssertEqual(result.config.bindings[.buttonB], .mouseButton(.left))
        XCTAssertTrue(result.warnings.contains { $0.contains("buttonA") && $0.contains("repeat") })
        XCTAssertTrue(result.warnings.contains { $0.contains("buttonB") && $0.contains("repeat") })
    }

    func testZeroTouchpadMouseSpeedFallsBackToDefault() throws {
        let json = #"{"touchpadMouseSpeed": 0}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpadMouseSpeed, 300)
        XCTAssertTrue(result.warnings.contains { $0.contains("touchpadMouseSpeed") })
    }

    func testNegativeTouchpadScrollSpeedFallsBackToDefault() throws {
        let json = #"{"touchpadScrollSpeed": -5}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpadScrollSpeed, 20)
        XCTAssertTrue(result.warnings.contains { $0.contains("touchpadScrollSpeed") })
    }

    func testTouchpadRoleParsesValidValue() throws {
        let json = #"{"touchpad": "scroll"}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpad, .scroll)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnknownTouchpadRoleWarnsAndFallsBackToNone() throws {
        let json = #"{"touchpad": "wat"}"#.data(using: .utf8)!
        let result = try ConfigLoader.load(from: json)
        XCTAssertEqual(result.config.touchpad, .none)
        XCTAssertTrue(result.warnings.contains { $0.contains("touchpad") })
    }

}
