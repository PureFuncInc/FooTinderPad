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
