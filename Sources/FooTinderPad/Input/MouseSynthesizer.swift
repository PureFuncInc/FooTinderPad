import Foundation

final class MouseSynthesizer {
    private let sink: EventSink
    private var heldButtons: Set<MouseButton> = []

    init(sink: EventSink) {
        self.sink = sink
    }

    func move(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        sink.mouseMove(deltaX: deltaX, deltaY: deltaY)
    }

    func scroll(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        sink.scroll(deltaX: deltaX, deltaY: deltaY)
    }

    func button(_ b: MouseButton, down: Bool) {
        if down {
            guard !heldButtons.contains(b) else { return }
            heldButtons.insert(b)
            sink.mouseButton(b, down: true)
        } else {
            guard heldButtons.contains(b) else { return }
            heldButtons.remove(b)
            sink.mouseButton(b, down: false)
        }
    }

    /// Releases every held mouse button. Used on config swap and controller switch.
    func drain() {
        for b in heldButtons {
            sink.mouseButton(b, down: false)
        }
        heldButtons.removeAll()
    }
}
