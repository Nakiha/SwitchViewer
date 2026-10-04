import Foundation
import Metal
import QuartzCore
import SwitchViewerInterpolation

/// Hardware resource ownership, separate from scheduling policy. Reserve on
/// main; acquisition runs off main; a lease is released at GPU completion or
/// rejection. It must not wait for presented callbacks to return GPU capacity.
final class GameDrawablePool {
    final class Lease {
        private let lock = NSLock()
        private var returnSlot: (() -> Void)?
        fileprivate init(returnSlot: @escaping () -> Void) { self.returnSlot = returnSlot }
        func release() {
            lock.lock(); let callback = returnSlot; returnSlot = nil; lock.unlock()
            callback?()
        }
        deinit { release() }
    }
    private let slots = DispatchSemaphore(value: 2)
    // Return expired, unpresented drawables after each job, before another job
    // waits on the same finite Core Animation pool.
    private let queue = DispatchQueue(label: "switchviewer.drawable-acquisition", qos: .userInteractive,
                                      autoreleaseFrequency: .workItem)
    private let trace: GameFrameTrace
    private let startedAt: Double
    private let injectStall: Bool
    private var testedStall = false // Acquisition queue only.
    private(set) var pendingAcquisition = 0 // Main only.
    init(trace: GameFrameTrace, startedAt: Double, injectStall: Bool) {
        self.trace = trace; self.startedAt = startedAt; self.injectStall = injectStall
    }
    func reserve() -> Lease? {
        guard slots.wait(timeout: .now()) == .success else { return nil }
        return Lease { [self] in slots.signal() }
    }
    func acquire(_ layer: CAMetalLayer, sequence: UInt64, expires: Double,
                 completion: @escaping (CAMetalDrawable?, Double) -> Void) {
        pendingAcquisition += 1
        trace.record(.init("drawableAcquireQueued", sequence: sequence, time: CACurrentMediaTime()))
        queue.async { [self] in
            let start = CACurrentMediaTime()
            trace.record(.init("drawableAcquireStart", sequence: sequence, time: start))
            if injectStall, start - startedAt >= 4, !testedStall {
                testedStall = true
                Thread.sleep(forTimeInterval: 1)
            }
            let drawable = CACurrentMediaTime() < expires ? layer.nextDrawable() : nil
            let end = CACurrentMediaTime()
            var event = GameFrameTrace.Event("drawableAcquireEnd", sequence: sequence, time: end)
            event.ready = start
            trace.record(event)
            DispatchQueue.main.async { [self] in
                pendingAcquisition -= 1
                var event = GameFrameTrace.Event("drawableReturnedToMain", sequence: sequence, time: CACurrentMediaTime())
                event.ready = end
                trace.record(event)
                completion(drawable, (end - start) * 1000)
            }
        }
    }
}
