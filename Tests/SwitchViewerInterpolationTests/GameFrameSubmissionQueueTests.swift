import XCTest
@testable import SwitchViewerInterpolation

final class GameFrameSubmissionQueueTests: XCTestCase {
    private final class Clock {
        var time = 0.0
        var tasks: [(Double, Int, () -> Void)] = []
        var nextID = 0
        func schedule(_ when: Double, _ task: @escaping () -> Void) {
            tasks.append((max(time, when), nextID, task)); nextID += 1
        }
        func advance(to target: Double) {
            while let next = tasks.indices.filter({ tasks[$0].0 <= target }).min(by: {
                tasks[$0].0 == tasks[$1].0 ? tasks[$0].1 < tasks[$1].1 : tasks[$0].0 < tasks[$1].0
            }) {
                let task = tasks.remove(at: next)
                time = task.0; task.2()
            }
            time = target
        }
        func queue() -> GameFrameSubmissionQueue {
            GameFrameSubmissionQueue(now: { self.time }, schedule: { self.schedule($0, $1) },
                                     deferTask: { self.schedule(self.time, $0) })
        }
    }
    private func plan(_ queue: GameFrameSubmissionQueue, sequence: UInt64, target: Double = 1) -> GameFramePresentationPolicy.Plan {
        queue.policy.plan(sequence: sequence, original: sequence % 2 == 0, target: target,
                          expires: target + 0.02, interval: 0.02, prequeued: false, options: .init())
    }
    func testOriginalPumpsReadyMidpointAndWaitsForItsCommitWithoutDoubleSubmitting() {
        let clock = Clock(), queue = clock.queue()
        var order: [String] = []
        queue.policy.beginMidpoint(1)
        // Midpoint's timer fires later, but the original must still pump it first.
        queue.enqueue(plan(queue, sequence: 1, target: 1.0005), submit: {
            order.append("midpoint started")
            clock.schedule(clock.time + 0.0004) {
                order.append("midpoint committed")
                queue.resolveMidpoint(1)
            }
        }, onHold: { _ in XCTFail("Only originals hold") })
        queue.enqueue(plan(queue, sequence: 2), submit: { order.append("original committed") }, onHold: { hold in
            XCTAssertLessThanOrEqual(hold.until - hold.nominal, 0.001001)
        })
        clock.advance(to: 2)
        XCTAssertEqual(order, ["midpoint started", "midpoint committed", "original committed"])
    }
    func testReadyMidpointThatNeverResolvesCannotHoldOriginalBeyondBound() {
        let clock = Clock(), queue = clock.queue()
        var times: [Double] = []
        queue.policy.beginMidpoint(1)
        queue.enqueue(plan(queue, sequence: 1), submit: {}, onHold: { _ in })
        queue.enqueue(plan(queue, sequence: 2), submit: { times.append(clock.time) }, onHold: { _ in })
        clock.advance(to: 2)
        XCTAssertEqual(times, [1.001])
    }
    func testUnfinishedAlgorithmDoesNotEarnExtraWait() {
        let clock = Clock(), queue = clock.queue()
        queue.policy.beginMidpoint(1)
        var submitted: Double?
        queue.enqueue(plan(queue, sequence: 2), submit: { submitted = clock.time }, onHold: { _ in XCTFail("Unfinished work must not extend the slot") })
        clock.advance(to: 2)
        XCTAssertEqual(submitted, 1)
    }
    func testResetCancelsTimersAndAlreadyDeferredWakeEvenWithReusedSequence() {
        let clock = Clock(), queue = clock.queue()
        var calls: [String] = []
        queue.policy.beginMidpoint(1)
        queue.enqueue(plan(queue, sequence: 1), submit: {
            queue.resolveMidpoint(1)
            queue.reset()
        }, onHold: { _ in })
        queue.enqueue(plan(queue, sequence: 2), submit: { calls.append("old") }, onHold: { _ in })
        clock.advance(to: 1)
        queue.enqueue(plan(queue, sequence: 2, target: 2), submit: { calls.append("new") }, onHold: { _ in })
        clock.advance(to: 3)
        XCTAssertEqual(calls, ["new"])
        // Reset after a midpoint has scheduled its original's deferred wake.
        queue.policy.beginMidpoint(3)
        queue.enqueue(plan(queue, sequence: 3, target: 4), submit: {}, onHold: { _ in })
        queue.enqueue(plan(queue, sequence: 4, target: 4), submit: { calls.append("stale wake") }, onHold: { _ in })
        clock.advance(to: 4)
        queue.resolveMidpoint(3)
        queue.reset()
        clock.advance(to: 5)
        XCTAssertEqual(calls, ["new"])
    }
}
