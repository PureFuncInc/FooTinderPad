import XCTest
import Carbon.HIToolbox
@testable import FooTinderPad

final class InputDispatcherTests: XCTestCase {

    func testDPadMouseModeMovesMouseAndIgnoresBindings() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(
                dpad: .mouse,
                dpadMouseSpeed: 3,
                bindings: [.dpadRight: .key(mainKey: CGKeyCode(kVK_RightArrow), modifiers: [], repeat: false)]
            )
        )

        dispatcher.handleButton(.dpadRight, pressed: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        dispatcher.handleButton(.dpadRight, pressed: false)

        XCTAssertEqual(sink.actions, [
            .mouseMove(3, 0),
        ])
    }

    func testDPadMouseModeUsesLinearTickScaling() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(dpad: .mouse, dpadMouseSpeed: 2)
        )

        dispatcher.handleButton(.dpadUp, pressed: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        dispatcher.tick(dt: 1.0 / 30.0)

        XCTAssertEqual(sink.actions, [
            .mouseMove(0, -2),
            .mouseMove(0, -4),
        ])
    }

    func testDPadBindingsModeKeepsOriginalButtonBindings() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(
                dpad: .bindings,
                bindings: [.dpadRight: .key(mainKey: CGKeyCode(kVK_RightArrow), modifiers: [], repeat: false)]
            )
        )

        dispatcher.handleButton(.dpadRight, pressed: true)
        dispatcher.handleButton(.dpadRight, pressed: false)

        XCTAssertEqual(sink.actions, [
            .keyEvent(CGKeyCode(kVK_RightArrow), true, [], false),
            .keyEvent(CGKeyCode(kVK_RightArrow), false, [], false),
        ])
    }

    func testDrainClearsHeldDPadMovement() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(dpad: .mouse, dpadMouseSpeed: 3)
        )

        dispatcher.handleButton(.dpadRight, pressed: true)
        dispatcher.drainHeldInputs()
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [])
    }

    func testTouchpadNoneEmitsNothing() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .none, touchpadMouseSpeed: 300, touchpadScrollSpeed: 20)
        )

        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        dispatcher.handleTouchpad(x: 0.5, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [])
    }

    func testTouchpadScrollEmitsScrollWithoutYInversion() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .scroll, touchpadScrollSpeed: 20)
        )

        // Touch begin (records last, emits zero).
        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        // Slide finger up by 0.1 normalised. Expected delta Y = 0.1 * 20 = 2 (no inversion for scroll).
        dispatcher.handleTouchpad(x: 0, y: 0.1, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [
            .scroll(0, 2),
        ])
    }

    func testTouchpadMouseEmitsMoveWithYInversion() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .mouse, touchpadMouseSpeed: 300)
        )

        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        // Finger up 0.1: with invertY true, delta Y = -30.
        dispatcher.handleTouchpad(x: 0, y: 0.1, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [
            .mouseMove(0, -30),
        ])
    }

    func testDrainClearsHeldTouchpadMotion() {
        let sink = RecordingSink()
        let dispatcher = makeDispatcher(
            sink: sink,
            config: makeConfig(touchpad: .mouse, touchpadMouseSpeed: 300)
        )

        dispatcher.handleTouchpad(x: 0, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)
        dispatcher.drainHeldInputs()
        // Even though we still report touched=true at a new position, the
        // processor was reset so the next tick is a fresh "begin".
        dispatcher.handleTouchpad(x: 0.5, y: 0, touched: true)
        dispatcher.tick(dt: 1.0 / 60.0)

        XCTAssertEqual(sink.actions, [])
    }

    private func makeDispatcher(sink: RecordingSink, config: ResolvedConfig) -> InputDispatcher {
        let key = KeySynthesizer(sink: sink)
        let mouse = MouseSynthesizer(sink: sink)
        return InputDispatcher(config: { config }, key: key, mouse: mouse, clock: { 0 })
    }

    private func makeConfig(
        dpad: DPadRole = .bindings,
        dpadMouseSpeed: Double = 3,
        touchpad: TouchpadRole = .none,
        touchpadMouseSpeed: Double = 300,
        touchpadScrollSpeed: Double = 20,
        bindings: [ControllerButton: ResolvedBinding] = [:]
    ) -> ResolvedConfig {
        var resolved = Dictionary(uniqueKeysWithValues: ControllerButton.allCases.map { ($0, ResolvedBinding.none) })
        for (button, binding) in bindings {
            resolved[button] = binding
        }
        return ResolvedConfig(
            deadzone: 0.15,
            mouseSpeed: 15,
            scrollSpeed: 5,
            leftStick: .none,
            rightStick: .none,
            dpad: dpad,
            dpadMouseSpeed: dpadMouseSpeed,
            dpadScrollSpeed: 2,
            touchpad: touchpad,
            touchpadMouseSpeed: touchpadMouseSpeed,
            touchpadScrollSpeed: touchpadScrollSpeed,
            bindings: resolved
        )
    }
}
