enum ControllerButton: String, CaseIterable, Hashable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftThumbstickButton, rightThumbstickButton
    case dpadUp, dpadDown, dpadLeft, dpadRight
    // PS5 Options (Apple framework: buttonMenu) and Create (Apple: buttonOptions).
    case optionsButton, createButton
    // PS4/PS5 touchpad click — only fires on DualShock4 / DualSense.
    case touchpadButton
}

enum MouseButton: String, Codable, Hashable {
    case left, right, middle
}

enum StickRole: String, Codable {
    case mouse, scroll, none
}

enum DPadRole: String, Codable {
    case bindings, mouse, scroll, none
}

enum ModifierKey: Hashable, CaseIterable {
    case leftCtrl, rightCtrl
    case leftAlt, rightAlt
    case leftShift, rightShift
    case leftCmd, rightCmd
    case fn
}
