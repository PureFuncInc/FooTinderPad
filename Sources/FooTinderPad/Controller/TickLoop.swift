import Foundation
import CoreVideo
import os

final class TickLoop {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "TickLoop")
    private weak var dispatcher: InputDispatcher?
    private var link: CVDisplayLink?
    private var lastHostTime: UInt64 = 0
    private var observerRef: UnsafeMutableRawPointer?

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func start() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let l = link else {
            log.error("CVDisplayLinkCreateWithActiveCGDisplays failed")
            return
        }
        self.link = l

        // passRetained: keep self alive until stop() releases. CVDisplayLinkStop
        // guarantees the output callback has returned before it returns, so
        // releasing inside stop() is safe.
        let observer = Unmanaged.passRetained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(l, { _, inNow, inOutputTime, _, _, ctx in
            let lp = Unmanaged<TickLoop>.fromOpaque(ctx!).takeUnretainedValue()
            let now = inNow.pointee.hostTime
            DispatchQueue.main.async { lp.tick(hostTime: now) }
            return kCVReturnSuccess
        }, observer)
        self.observerRef = observer
        CVDisplayLinkStart(l)
        log.info("tick loop started")
    }

    func stop() {
        if let l = link {
            CVDisplayLinkStop(l)
        }
        link = nil
        if let observer = observerRef {
            Unmanaged<TickLoop>.fromOpaque(observer).release()
            observerRef = nil
        }
    }

    private func tick(hostTime: UInt64) {
        let dt: Double
        if lastHostTime == 0 {
            dt = 1.0 / 60.0
        } else {
            let elapsed = hostTime &- lastHostTime
            // Convert mach host time delta to seconds
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let nanos = elapsed * UInt64(info.numer) / UInt64(info.denom)
            dt = Double(nanos) / 1_000_000_000.0
        }
        lastHostTime = hostTime
        dispatcher?.tick(dt: dt.clamped(to: 1.0/240.0 ... 1.0/30.0))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
