import Foundation
import GameController
import os

final class ControllerManager {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "ControllerManager")
    private weak var dispatcher: InputDispatcher?
    private var stack: [GCController] = []
    private(set) var active: GCController?

    /// Called whenever the active controller changes (connect / disconnect / switch).
    var onActiveChanged: ((GCController?) -> Void)?

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func start() {
        // Receive controller events even when not frontmost. Without this,
        // gamecontrollerd routes events only to the foreground app — so a
        // menu-bar utility like ours never sees presses while the user types
        // into another window. Required for our LSUIElement architecture.
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(self, selector: #selector(didConnect),
                                               name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didDisconnect),
                                               name: .GCControllerDidDisconnect, object: nil)
        for c in GCController.controllers() { adopt(c) }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        unwireCurrent()
        stack.removeAll()
        active = nil
        GCController.shouldMonitorBackgroundEvents = false
    }

    @objc private func didConnect(_ note: Notification) {
        guard let c = note.object as? GCController else { return }
        adopt(c)
    }

    @objc private func didDisconnect(_ note: Notification) {
        guard let c = note.object as? GCController else { return }
        log.info("controller disconnected: \(c.vendorName ?? "?", privacy: .public)")
        stack.removeAll { $0 === c }
        if active === c {
            unwireCurrent()
            active = nil
            if let next = stack.last { switchTo(next) } else { onActiveChanged?(nil) }
        }
    }

    private func adopt(_ c: GCController) {
        guard c.extendedGamepad != nil else {
            log.info("ignoring non-extended controller: \(c.vendorName ?? "?", privacy: .public)")
            return
        }
        log.info("controller connected: \(c.vendorName ?? "?", privacy: .public)")
        if !stack.contains(where: { $0 === c }) { stack.append(c) }
        switchTo(c)
    }

    private func switchTo(_ c: GCController) {
        unwireCurrent()
        active = c
        wire(c)
        log.info("active controller: \(c.vendorName ?? "?", privacy: .public)")
        onActiveChanged?(c)
    }

    private func unwireCurrent() {
        guard let prev = active, let pad = prev.extendedGamepad else { return }
        let buttons: [GCControllerButtonInput?] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.leftShoulder, pad.rightShoulder,
            pad.leftThumbstickButton, pad.rightThumbstickButton,
            pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right,
            pad.buttonMenu, pad.buttonOptions,
            Self.touchpadButton(of: pad),
        ]
        for b in buttons { b?.valueChangedHandler = nil }
        pad.leftTrigger.valueChangedHandler = nil
        pad.rightTrigger.valueChangedHandler = nil
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
        if let surface = Self.touchpadOne(of: pad) {
            surface.valueChangedHandler = nil
        }
        dispatcher?.drainHeldInputs()
    }

    /// Touchpad click button is only present on PS4 (DualShock) / PS5 (DualSense).
    /// Returns nil for Xbox and other extended-gamepad-shaped controllers.
    private static func touchpadButton(of pad: GCExtendedGamepad) -> GCControllerButtonInput? {
        if let ds = pad as? GCDualSenseGamepad { return ds.touchpadButton }
        if let ds = pad as? GCDualShockGamepad { return ds.touchpadButton }
        return nil
    }

    /// Touchpad surface (single-finger primary) — only present on PS4 (DualShock) /
    /// PS5 (DualSense). Returns nil for other extended-gamepad-shaped
    /// controllers, in which case the surface wiring is silently skipped.
    private static func touchpadOne(of pad: GCExtendedGamepad) -> GCControllerDirectionPad? {
        if let ds = pad as? GCDualSenseGamepad { return ds.touchpadPrimary }
        if let ds = pad as? GCDualShockGamepad { return ds.touchpadPrimary }
        return nil
    }

    private func wire(_ c: GCController) {
        guard let pad = c.extendedGamepad, let dispatcher = dispatcher else { return }

        // Binary buttons
        let map: [(GCControllerButtonInput, ControllerButton)] = [
            (pad.buttonA, .buttonA), (pad.buttonB, .buttonB),
            (pad.buttonX, .buttonX), (pad.buttonY, .buttonY),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown),
            (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
        ]
        for (input, name) in map {
            input.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(name, pressed: pressed)
            }
        }
        if let lts = pad.leftThumbstickButton {
            lts.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(.leftThumbstickButton, pressed: pressed)
            }
        }
        if let rts = pad.rightThumbstickButton {
            rts.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(.rightThumbstickButton, pressed: pressed)
            }
        }

        // PS5 Options (Apple: buttonMenu) is non-optional; Create (Apple: buttonOptions)
        // was added in macOS 10.15 and is exposed as optional.
        pad.buttonMenu.valueChangedHandler = { [weak dispatcher] _, _, pressed in
            dispatcher?.handleButton(.optionsButton, pressed: pressed)
        }
        if let create = pad.buttonOptions {
            create.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(.createButton, pressed: pressed)
            }
        }

        // PS4/PS5 touchpad click — only on DualShock4 / DualSense.
        if let touchpad = Self.touchpadButton(of: pad) {
            touchpad.valueChangedHandler = { [weak dispatcher] _, _, pressed in
                dispatcher?.handleButton(.touchpadButton, pressed: pressed)
            }
        }

        // PS4/PS5 touchpad surface (single-finger, delta mode).
        if let surface = Self.touchpadOne(of: pad) {
            surface.valueChangedHandler = { [weak dispatcher] _, x, y in
                // Heuristic: if both axes report exactly zero, treat as
                // "no finger present". The framework reports (0, 0) when
                // the touch is released; a real touch landing exactly at
                // dead-centre is rare and only loses one delta tick.
                let touched = (x != 0 || y != 0)
                dispatcher?.handleTouchpad(x: Double(x), y: Double(y), touched: touched)
            }
        }

        // Triggers (analog → hysteresis in dispatcher)
        pad.leftTrigger.valueChangedHandler = { [weak dispatcher] _, value, _ in
            dispatcher?.handleTrigger(.leftTrigger, value: Double(value))
        }
        pad.rightTrigger.valueChangedHandler = { [weak dispatcher] _, value, _ in
            dispatcher?.handleTrigger(.rightTrigger, value: Double(value))
        }

        // Sticks (sample only; emission happens in TickLoop)
        pad.leftThumbstick.valueChangedHandler = { [weak dispatcher] _, x, y in
            dispatcher?.updateLeftStick(x: Double(x), y: Double(y))
        }
        pad.rightThumbstick.valueChangedHandler = { [weak dispatcher] _, x, y in
            dispatcher?.updateRightStick(x: Double(x), y: Double(y))
        }
    }
}
