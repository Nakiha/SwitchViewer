import XCTest
@testable import SwitchViewerInterpolation

final class TimedFrameQueueTests: XCTestCase {
    func testLateMidpointCannotRewindDisplayedSource() {
        let queue = TimedFrameQueue<String>()
        let generation = queue.generation
        queue.enqueue("source", mediaTime: 2, displayTime: 10, generation: generation)
        XCTAssertEqual(queue.take(at: 10)?.frame, "source")
        XCTAssertFalse(queue.enqueue("late midpoint", mediaTime: 1.5, displayTime: 9,
                                     generation: generation))
        XCTAssertNil(queue.take(at: 11))
    }

    func testMidpointCompletingAfterSourceEnqueueStillPlaysInOrder() {
        let queue = TimedFrameQueue<String>()
        let generation = queue.generation
        queue.enqueue("next source", mediaTime: 2, displayTime: 11, generation: generation)
        queue.enqueue("midpoint", mediaTime: 1.5, displayTime: 10.5, generation: generation)
        XCTAssertNil(queue.take(at: 10))
        XCTAssertEqual(queue.take(at: 10.5)?.frame, "midpoint")
        XCTAssertEqual(queue.take(at: 11)?.frame, "next source")
    }

    func testResetRejectsPreviousSessionCompletionAndAcceptsNewTimeline() {
        let queue = TimedFrameQueue<String>()
        let old = queue.generation
        queue.enqueue("old", mediaTime: 100, displayTime: 100, generation: old)
        let new = queue.reset()
        XCTAssertFalse(queue.enqueue("old completion", mediaTime: 101, displayTime: 101, generation: old))
        XCTAssertNil(queue.take(at: 200))
        XCTAssertTrue(queue.enqueue("new", mediaTime: 0, displayTime: 1, generation: new))
        XCTAssertEqual(queue.take(at: 1)?.frame, "new")
    }

    func testCapacityAndMissedRefreshChooseLatestDueFrame() {
        let queue = TimedFrameQueue<Int>(capacity: 2)
        for i in 0..<5 { queue.enqueue(i, mediaTime: Double(i), displayTime: Double(i), generation: queue.generation) }
        XCTAssertNil(queue.take(at: 2))
        XCTAssertEqual(queue.take(at: 4)?.frame, 4)
        XCTAssertNil(queue.take(at: 4))
    }

    func testNonfiniteTimesAndReplacement() {
        let queue = TimedFrameQueue<String>()
        let generation = queue.generation
        XCTAssertFalse(queue.enqueue("bad", mediaTime: .nan, displayTime: 1, generation: generation))
        XCTAssertFalse(queue.enqueue("bad", mediaTime: 1, displayTime: .infinity, generation: generation))
        queue.enqueue("old", mediaTime: 1, displayTime: 2, generation: generation)
        queue.enqueue("replacement", mediaTime: 1, displayTime: 2, generation: generation)
        XCTAssertNil(queue.take(at: .nan))
        XCTAssertEqual(queue.take(at: 2)?.frame, "replacement")
        XCTAssertNil(queue.take(at: 2))
    }
}
