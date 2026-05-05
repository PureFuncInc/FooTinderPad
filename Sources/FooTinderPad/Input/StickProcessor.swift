import Foundation

struct StickEmit: Equatable {
    let deltaX: Int
    let deltaY: Int
}

struct StickProcessor {
    var deadzone: Double

    private var accumX: Double = 0
    private var accumY: Double = 0

    init(deadzone: Double) {
        self.deadzone = max(0.0, min(0.49, deadzone))
    }

    mutating func tick(x: Double, y: Double, speed: Double, tickScale: Double, invertY: Bool) -> StickEmit {
        let mag = (x * x + y * y).squareRoot()
        guard mag >= deadzone, mag > 0 else {
            accumX = 0; accumY = 0
            return StickEmit(deltaX: 0, deltaY: 0)
        }
        let n = (mag - deadzone) / (1 - deadzone)
        let scale = n / mag
        let nx = x * scale
        let ny = y * scale

        accumX += nx * speed * tickScale
        accumY += (invertY ? -1 : 1) * ny * speed * tickScale

        let emitX = Int(accumX.rounded(.towardZero))
        let emitY = Int(accumY.rounded(.towardZero))
        accumX -= Double(emitX)
        accumY -= Double(emitY)

        return StickEmit(deltaX: emitX, deltaY: emitY)
    }
}
