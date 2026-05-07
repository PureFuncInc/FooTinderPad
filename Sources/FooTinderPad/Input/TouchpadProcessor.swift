import Foundation

/// Delta-mode processor for the PS4/PS5 controller touch surface.
/// Reuses `StickEmit` as the output type since it carries the same shape
/// (integer X / Y delta to feed into mouse.move or mouse.scroll).
struct TouchpadProcessor {

    private var lastX: Double?
    private var lastY: Double?
    private var accumX: Double = 0
    private var accumY: Double = 0

    mutating func tick(x: Double, y: Double, touched: Bool,
                       speed: Double, tickScale: Double,
                       invertY: Bool) -> StickEmit {
        guard touched else {
            lastX = nil
            lastY = nil
            accumX = 0
            accumY = 0
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        guard let lx = lastX, let ly = lastY else {
            lastX = x
            lastY = y
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        let dx = x - lx
        let dy = y - ly
        lastX = x
        lastY = y

        accumX += dx * speed * tickScale
        accumY += (invertY ? -1 : 1) * dy * speed * tickScale

        let emitX = Int(accumX.rounded(.towardZero))
        let emitY = Int(accumY.rounded(.towardZero))
        accumX -= Double(emitX)
        accumY -= Double(emitY)

        return StickEmit(deltaX: emitX, deltaY: emitY)
    }

    mutating func drain() {
        lastX = nil
        lastY = nil
        accumX = 0
        accumY = 0
    }
}
