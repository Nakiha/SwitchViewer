import XCTest
@testable import SwitchViewerInterpolation

final class GameFrameTraceTests: XCTestCase {
    func testRecordingIsOptInTimeBoundedAndDrainedOnce() {
        let trace = GameFrameTrace()
        trace.record(.init("input", sequence: 1, time: 1))
        XCTAssertTrue(trace.takeBatch().events.isEmpty)
        trace.begin(at: 2, duration: 3)
        for time in [1.9, 2, 4.9, 5, Double.nan] {
            trace.record(.init("input", sequence: 2, time: time))
        }
        XCTAssertEqual(trace.takeBatch().events.map(\.time), [2, 4.9])
        XCTAssertTrue(trace.takeBatch().events.isEmpty)
    }

    func testOverflowAndRestartAreVisibleRatherThanSilentlyMixingRecordings() {
        let trace = GameFrameTrace(capacity: 2)
        let first = trace.begin(at: 1)
        trace.record(.init("input", sequence: 2, time: 1))
        let second = trace.begin(at: 2)
        trace.record(.init("input", sequence: 4, time: 2))
        trace.record(.init("input", sequence: 6, time: 3))
        let batch = trace.takeBatch()
        XCTAssertEqual(batch.events.map(\.traceID), [first, second])
        XCTAssertEqual(batch.lost, 1)
        XCTAssertEqual(trace.takeBatch().lost, 0)
    }
}
