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

private extension DPadRole {
    var stickRole: StickRole {
        switch self {
        case .mouse: return .mouse
        case .scroll: return .scroll
        case .bindings, .none: return .none
        }
    }
}

private extension TouchpadRole {
    var invertY: Bool {
        switch self {
        case .mouse: return true
        case .scroll: return false
        case .none: return false
        }
    }
}

final class InputDispatcher {
    /// Curve tuning lives in source on purpose. These are not JSON config knobs.
    private static let mouseCurve: Double = 4.0
    private static let scrollCurve: Double = 1.0
    private static let dpadCurve: Double = 1.0

    private let configProvider: () -> ResolvedConfig
    private let key: KeySynthesizer
    private let mouse: MouseSynthesizer
    private let clock: () -> TimeInterval
    private let repeater = RepeatScheduler()
    private var leftStick = StickProcessor(deadzone: 0.15)
    private var rightStick = StickProcessor(deadzone: 0.15)
    private var dpadStick = StickProcessor(deadzone: 0)
    private var leftTrigger = TriggerHysteresis()
    private var rightTrigger = TriggerHysteresis()
    private var dpadPressed: Set<ControllerButton> = []
    private var lastLeftX: Double = 0
    private var lastLeftY: Double = 0
    private var lastRightX: Double = 0
    private var lastRightY: Double = 0
    private var lastTouchpadX: Double = 0
    private var lastTouchpadY: Double = 0
    private var touchpadActive: Bool = false
    private var touchpadProcessor = TouchpadProcessor()

    init(config: @escaping () -> ResolvedConfig,
         key: KeySynthesizer,
         mouse: MouseSynthesizer,
         clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.configProvider = config
        self.key = key
        self.mouse = mouse
        self.clock = clock
    }

    // MARK: - inbound from controller

    func handleButton(_ button: ControllerButton, pressed: Bool) {
        let cfg = configProvider()
        if isDPadButton(button), cfg.dpad != .bindings {
            updateDPad(button, pressed: pressed)
            return
        }
        guard let binding = cfg.bindings[button] else { return }
        applyBinding(binding, button: button, pressed: pressed)
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

    func handleTouchpad(x: Double, y: Double, touched: Bool) {
        lastTouchpadX = x
        lastTouchpadY = y
        touchpadActive = touched
    }

    // MARK: - tick (called by TickLoop)

    func tick(dt: Double) {
        repeater.tick(now: clock()) { [weak key] _, parsed in
            key?.repeatPress(parsed)
        }
        let cfg = configProvider()
        leftStick.deadzone = cfg.deadzone
        rightStick.deadzone = cfg.deadzone
        let scale = dt * 60
        emit(role: cfg.leftStick, x: lastLeftX, y: lastLeftY,
             speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed,
             curveMouse: Self.mouseCurve, curveScroll: Self.scrollCurve,
             processor: &leftStick, tickScale: scale)
        emit(role: cfg.rightStick, x: lastRightX, y: lastRightY,
             speedMouse: cfg.mouseSpeed, speedScroll: cfg.scrollSpeed,
             curveMouse: Self.mouseCurve, curveScroll: Self.scrollCurve,
             processor: &rightStick, tickScale: scale)
        let dpadVector = currentDPadVector()
        emit(role: cfg.dpad.stickRole, x: dpadVector.x, y: dpadVector.y,
             speedMouse: cfg.dpadMouseSpeed, speedScroll: cfg.dpadScrollSpeed,
             curveMouse: Self.dpadCurve, curveScroll: Self.dpadCurve,
             processor: &dpadStick, tickScale: scale)
        emitTouchpad(role: cfg.touchpad,
                     x: lastTouchpadX, y: lastTouchpadY, touched: touchpadActive,
                     speedMouse: cfg.touchpadMouseSpeed,
                     speedScroll: cfg.touchpadScrollSpeed,
                     processor: &touchpadProcessor, tickScale: scale)
    }

    private func emit(role: StickRole, x: Double, y: Double,
                      speedMouse: Double, speedScroll: Double,
                      curveMouse: Double,
                      curveScroll: Double,
                      processor: inout StickProcessor, tickScale: Double) {
        switch role {
        case .none:
            return
        case .mouse:
            let out = processor.tick(x: x, y: y, speed: speedMouse,
                                     curve: curveMouse,
                                     tickScale: tickScale, invertY: true)
            mouse.move(deltaX: out.deltaX, deltaY: out.deltaY)
        case .scroll:
            let out = processor.tick(x: x, y: y, speed: speedScroll,
                                     curve: curveScroll,
                                     tickScale: tickScale, invertY: false)
            mouse.scroll(deltaX: out.deltaX, deltaY: out.deltaY)
        }
    }

    private func emitTouchpad(role: TouchpadRole, x: Double, y: Double, touched: Bool,
                              speedMouse: Double, speedScroll: Double,
                              processor: inout TouchpadProcessor, tickScale: Double) {
        switch role {
        case .none:
            return
        case .mouse:
            let out = processor.tick(x: x, y: y, touched: touched,
                                     speed: speedMouse,
                                     tickScale: tickScale, invertY: role.invertY)
            mouse.move(deltaX: out.deltaX, deltaY: out.deltaY)
        case .scroll:
            let out = processor.tick(x: x, y: y, touched: touched,
                                     speed: speedScroll,
                                     tickScale: tickScale, invertY: role.invertY)
            mouse.scroll(deltaX: out.deltaX, deltaY: out.deltaY)
        }
    }

    func drainHeldInputs() {
        repeater.clear()
        dpadPressed.removeAll()
        touchpadActive = false
        lastTouchpadX = 0
        lastTouchpadY = 0
        touchpadProcessor.drain()
        key.drain()
        mouse.drain()
    }

    // MARK: - private

    private func isDPadButton(_ button: ControllerButton) -> Bool {
        switch button {
        case .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            return true
        default:
            return false
        }
    }

    private func updateDPad(_ button: ControllerButton, pressed: Bool) {
        if pressed {
            dpadPressed.insert(button)
        } else {
            dpadPressed.remove(button)
        }
    }

    private func currentDPadVector() -> (x: Double, y: Double) {
        var x = 0.0
        var y = 0.0
        if dpadPressed.contains(.dpadLeft) { x -= 1 }
        if dpadPressed.contains(.dpadRight) { x += 1 }
        if dpadPressed.contains(.dpadUp) { y += 1 }
        if dpadPressed.contains(.dpadDown) { y -= 1 }
        let mag = (x * x + y * y).squareRoot()
        guard mag > 1 else { return (x, y) }
        return (x / mag, y / mag)
    }

    private func applyBinding(_ binding: ResolvedBinding, button: ControllerButton, pressed: Bool) {
        switch binding {
        case .none:
            return
        case .key(let main, let mods, let isRepeat):
            let parsed = ParsedKey(mainKey: main, modifiers: mods)
            if pressed {
                key.press(parsed)
                if isRepeat {
                    repeater.start(button: button, parsedKey: parsed, now: clock())
                }
            } else {
                repeater.stop(button: button)
                key.release(parsed)
            }
        case .mouseButton(let b):
            mouse.button(b, down: pressed)
        }
    }
}
