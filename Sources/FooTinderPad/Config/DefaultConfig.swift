import Foundation

enum DefaultConfig {

    /// Embedded textual default — same content as Resources/DefaultConfig.json.
    /// Used when the bundle resource cannot be read (defensive fallback).
    static let json: String = #"""
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
        "buttonY": { "type": "key", "key": "Delete" },
        "leftShoulder": { "type": "key", "key": "Escape" },
        "rightShoulder": { "type": "mouseButton", "button": "right" },
        "leftTrigger": { "type": "key", "key": "RightShift" },
        "rightTrigger": { "type": "key", "key": "Alt+Return" },
        "leftThumbstickButton": { "type": "none" },
        "rightThumbstickButton": { "type": "none" },
        "dpadUp": { "type": "key", "key": "Up" },
        "dpadDown": { "type": "key", "key": "Down" },
        "dpadLeft": { "type": "key", "key": "Left" },
        "dpadRight": { "type": "key", "key": "Right" },
        "optionsButton": { "type": "none" },
        "createButton": { "type": "none" },
        "touchpadButton": { "type": "none" }
      }
    }
    """#

    static var data: Data { json.data(using: .utf8)! }
}
