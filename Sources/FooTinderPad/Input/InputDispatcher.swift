import Foundation

struct TriggerHysteresis {
    enum Edge { case none, pressed, released }
    private(set) var pressed = false
    mutating func update(_ value: Double) -> Edge {
        if !pressed && value > 0.55 { pressed = true; return .pressed }
        if pressed && value < 0.45 { pressed = false; return .released }
        return .none
    }
}

final class InputDispatcher {
    /// Response curves for the stick → mouse / scroll mapping. Hardcoded
    /// internal tuning parameters; not exposed via JSON config. To adjust the
    /// feel, edit these constants and rebuild.
    private static let mouseCurve: Double = 4.0
    private static let scrollCurve: Double = 1.0

    private let configProvider: () -> ResolvedConfig
    private let key: KeySynthesizer
    private let mouse: MouseSynthesizer
    private var leftStick = StickProcessor(deadzone: 0.15)
    private var rightStick = StickProcessor(deadzone: 0.15)
    private var leftTrigger = TriggerHysteresis()
    private var rightTrigger = TriggerHysteresis()
    private var lastLeftX: Double = 0
    private var lastLeftY: Double = 0
    private var lastRightX: Double = 0
    private var lastRightY: Double = 0

    init(config: @escaping () -> ResolvedConfig, key: KeySynthesizer, mouse: MouseSynthesizer) {
        self.configProvider = config
        self.key = key
        self.mouse = mouse
    }

    // MARK: - inbound from controller

    func handleButton(_ button: ControllerButton, pressed: Bool) {
        guard let binding = configProvider().bindings[button] else { return }
        applyBinding(binding, pressed: pressed)
    }

    func handleTrigger(_ button: ControllerButton, value: Double) {
        let edge: TriggerHysteresis.Edge
        switch button {
        case .leftTrigger:  edge = leftTrigger.update(value)
        case .rightTrigger: edge = rightTrigger.update(value)
        default: return
        }
        switch edge {
        case .pressed:  handleButton(button, pressed: true)
        case .released: handleButton(button, pressed: false)
        case .none:     break
        }
    }

    func updateLeftStick(x: Double, y: Double)  { lastLeftX = x; lastLeftY = y }
    func updateRightStick(x: Double, y: Double) { lastRightX = x; lastRightY = y }

    // MARK: - tick (called by TickLoop)

    func tick(dt: Double) {
        let cfg = configProvider()
        leftStick.deadzone = cfg.deadzone
        rightStick.deadzone = cfg.deadzone
        let scale = dt * 60
        emit(role: cfg.leftStick, x: lastLeftX, y: lastLeftY,
             speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed,
             processor: &leftStick, tickScale: scale)
        emit(role: cfg.rightStick, x: lastRightX, y: lastRightY,
             speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed,
             processor: &rightStick, tickScale: scale)
    }

    private func emit(role: StickRole, x: Double, y: Double,
                      speedMouse: Double, speedScroll: Double,
                      processor: inout StickProcessor, tickScale: Double) {
        switch role {
        case .none:
            return
        case .mouse:
            let out = processor.tick(x: x, y: y, speed: speedMouse,
                                     curve: Self.mouseCurve,
                                     tickScale: tickScale, invertY: true)
            mouse.move(deltaX: out.deltaX, deltaY: out.deltaY)
        case .scroll:
            let out = processor.tick(x: x, y: y, speed: speedScroll,
                                     curve: Self.scrollCurve,
                                     tickScale: tickScale, invertY: false)
            mouse.scroll(deltaX: out.deltaX, deltaY: out.deltaY)
        }
    }

    func drainHeldInputs() {
        key.drain()
        mouse.drain()
    }

    // MARK: - private

    private func applyBinding(_ binding: ResolvedBinding, pressed: Bool) {
        switch binding {
        case .none:
            return
        case .key(let main, let mods):
            let parsed = ParsedKey(mainKey: main, modifiers: mods)
            if pressed { key.press(parsed) } else { key.release(parsed) }
        case .mouseButton(let b):
            mouse.button(b, down: pressed)
        }
    }
}
