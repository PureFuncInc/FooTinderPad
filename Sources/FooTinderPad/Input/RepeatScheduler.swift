import Foundation

/// Per-button hold tracker that emits repeat events on tick after an initial
/// delay, then at a fixed interval. Time is passed in by the caller so the
/// scheduler is fully deterministic for tests.
final class RepeatScheduler {
    static let initialDelay: TimeInterval = 0.400
    static let interval: TimeInterval = 0.033

    private struct Entry {
        let parsedKey: ParsedKey
        let pressTime: TimeInterval
        var lastEmitTime: TimeInterval
    }

    private var held: [ControllerButton: Entry] = [:]

    func start(button: ControllerButton, parsedKey: ParsedKey, now: TimeInterval) {
        held[button] = Entry(parsedKey: parsedKey, pressTime: now, lastEmitTime: 0)
    }

    func stop(button: ControllerButton) {
        held.removeValue(forKey: button)
    }

    func clear() {
        held.removeAll()
    }

    func tick(now: TimeInterval, emit: (ControllerButton, ParsedKey) -> Void) {
        // Tiny epsilon absorbs IEEE-754 rounding when callers pass exact decimal literals.
        let eps: TimeInterval = 1e-9
        for (button, entry) in held {
            let sincePress = now - entry.pressTime
            guard sincePress >= Self.initialDelay - eps else { continue }

            // First emit after the initial delay; subsequent emits paced by interval.
            let shouldEmit: Bool
            if entry.lastEmitTime == 0 {
                shouldEmit = true
            } else {
                shouldEmit = (now - entry.lastEmitTime) >= Self.interval - eps
            }
            if shouldEmit {
                emit(button, entry.parsedKey)
                held[button]?.lastEmitTime = now
            }
        }
    }
}
