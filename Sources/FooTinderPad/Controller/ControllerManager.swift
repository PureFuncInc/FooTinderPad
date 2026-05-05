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
    }

    @objc private func didConnect(_ note: Notification) {
        guard let c = note.object as? GCController else { return }
        adopt(c)
    }

    @objc private func didDisconnect(_ note: Notification) {
        guard let c = note.object as? GCController else { return }
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
        if !stack.contains(where: { $0 === c }) { stack.append(c) }
        switchTo(c)
    }

    private func switchTo(_ c: GCController) {
        unwireCurrent()
        active = c
        wire(c)
        onActiveChanged?(c)
    }

    private func unwireCurrent() {
        guard let prev = active, let pad = prev.extendedGamepad else { return }
        let buttons: [GCControllerButtonInput?] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.leftShoulder, pad.rightShoulder,
            pad.leftThumbstickButton, pad.rightThumbstickButton,
            pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right,
        ]
        for b in buttons { b?.valueChangedHandler = nil }
        pad.leftTrigger.valueChangedHandler = nil
        pad.rightTrigger.valueChangedHandler = nil
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
        dispatcher?.drainHeldInputs()
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
