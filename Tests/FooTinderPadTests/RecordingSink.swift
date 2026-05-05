import Foundation
import CoreGraphics
@testable import FooTinderPad

final class RecordingSink: EventSink {
    enum Action: Equatable {
        case mouseMove(Int, Int)
        case mouseButton(MouseButton, Bool)
        case scroll(Int, Int)
        case keyEvent(CGKeyCode, Bool, CGEventFlags)
    }

    private(set) var actions: [Action] = []

    func mouseMove(deltaX: Int, deltaY: Int)            { actions.append(.mouseMove(deltaX, deltaY)) }
    func mouseButton(_ button: MouseButton, down: Bool) { actions.append(.mouseButton(button, down)) }
    func scroll(deltaX: Int, deltaY: Int)               { actions.append(.scroll(deltaX, deltaY)) }
    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        actions.append(.keyEvent(keyCode, down, flags))
    }
}

extension CGEventFlags: @retroactive Equatable {
    public static func == (lhs: CGEventFlags, rhs: CGEventFlags) -> Bool { lhs.rawValue == rhs.rawValue }
}
