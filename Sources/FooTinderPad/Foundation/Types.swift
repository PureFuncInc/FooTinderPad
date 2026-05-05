enum ControllerButton: String, CaseIterable, Hashable {
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case leftThumbstickButton, rightThumbstickButton
    case dpadUp, dpadDown, dpadLeft, dpadRight
}

enum MouseButton: String, Codable, Hashable {
    case left, right, middle
}

enum StickRole: String, Codable {
    case mouse, scroll, none
}

enum ModifierKey: Hashable, CaseIterable {
    case leftCtrl, rightCtrl
    case leftAlt, rightAlt
    case leftShift, rightShift
    case leftCmd, rightCmd
    case fn
}
