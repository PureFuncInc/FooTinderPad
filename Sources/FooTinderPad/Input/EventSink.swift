import Foundation
import CoreGraphics

protocol EventSink: AnyObject {
    func mouseMove(deltaX: Int, deltaY: Int)
    func mouseButton(_ button: MouseButton, down: Bool)
    func scroll(deltaX: Int, deltaY: Int)
    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags)
}

final class CGEventSink: EventSink {

    // Callers (MouseSynthesizer.move / .scroll) already short-circuit on
    // zero deltas — no need to guard here too.
    func mouseMove(deltaX: Int, deltaY: Int) {
        let cur = CGEvent(source: nil)?.location ?? .zero
        let raw = CGPoint(x: cur.x + CGFloat(deltaX), y: cur.y + CGFloat(deltaY))
        // CGEvent does not auto-clamp mouseCursorPosition to active displays,
        // so an unclamped target warps the cursor off-screen and "loses" it.
        let target = Self.clamp(target: raw, displays: Self.activeDisplayBounds())
        let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)
        ev?.post(tap: .cghidEventTap)
    }

    static func clamp(target: CGPoint, displays: [CGRect]) -> CGPoint {
        guard !displays.isEmpty else { return target }
        if displays.contains(where: { $0.contains(target) }) { return target }
        var best = target
        var bestDist = CGFloat.infinity
        for rect in displays {
            // maxX/maxY are exclusive; subtract 1 so the cursor stays visible on-screen.
            let cx = min(max(target.x, rect.minX), rect.maxX - 1)
            let cy = min(max(target.y, rect.minY), rect.maxY - 1)
            let dx = cx - target.x
            let dy = cy - target.y
            let d = dx * dx + dy * dy
            if d < bestDist {
                bestDist = d
                best = CGPoint(x: cx, y: cy)
            }
        }
        return best
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    func mouseButton(_ button: MouseButton, down: Bool) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let (type, cgButton): (CGEventType, CGMouseButton)
        switch (button, down) {
        case (.left, true):   (type, cgButton) = (.leftMouseDown, .left)
        case (.left, false):  (type, cgButton) = (.leftMouseUp, .left)
        case (.right, true):  (type, cgButton) = (.rightMouseDown, .right)
        case (.right, false): (type, cgButton) = (.rightMouseUp, .right)
        case (.middle, true): (type, cgButton) = (.otherMouseDown, .center)
        case (.middle, false):(type, cgButton) = (.otherMouseUp, .center)
        }
        let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: pos, mouseButton: cgButton)
        ev?.post(tap: .cghidEventTap)
    }

    func scroll(deltaX: Int, deltaY: Int) {
        let ev = CGEvent(scrollWheelEvent2Source: nil,
                         units: .line,
                         wheelCount: 2,
                         wheel1: Int32(deltaY),
                         wheel2: Int32(deltaX),
                         wheel3: 0)
        ev?.post(tap: .cghidEventTap)
    }

    func keyEvent(keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }
}
