import Foundation

enum DefaultConfig {

    /// Embedded textual default — same content as Resources/DefaultConfig.json.
    /// Used when the bundle resource cannot be read (defensive fallback).
    static let json: String = #"""
    {
      "deadzone": 0.15,
      "mouseSpeed": 15,
      "scrollSpeed": 2,
      "leftStick": "mouse",
      "rightStick": "scroll",
      "touchpad": "none",
      "touchpadMouseSpeed": 300,
      "touchpadScrollSpeed": 20,
      "bindings": {
        "buttonA": { "type": "key", "key": "Space", "repeat": true },
        "buttonB": { "type": "key", "key": "Return" },
        "buttonX": { "type": "mouseButton", "button": "left" },
        "buttonY": { "type": "key", "key": "Backspace", "repeat": true },
        "leftShoulder": { "type": "key", "key": "Escape" },
        "rightShoulder": { "type": "mouseButton", "button": "right" },
        "leftTrigger": { "type": "key", "key": "RightShift" },
        "rightTrigger": { "type": "key", "key": "Alt+Return" },
        "leftThumbstickButton": { "type": "key", "key": "Cmd+C" },
        "rightThumbstickButton": { "type": "key", "key": "Cmd+V" },
        "dpadUp": { "type": "key", "key": "Up", "repeat": true },
        "dpadDown": { "type": "key", "key": "Down", "repeat": true },
        "dpadLeft": { "type": "key", "key": "Left", "repeat": true },
        "dpadRight": { "type": "key", "key": "Right", "repeat": true },
        "createButton": { "type": "key", "key": "Fn+Ctrl+Left" },
        "optionsButton": { "type": "key", "key": "Fn+Ctrl+Right" }
      }
    }
    """#

    static var data: Data { json.data(using: .utf8)! }
}
