import XCTest
@testable import SwitchViewerInterpolation

final class SourceFrameRateTests: XCTestCase {
    func testAlternatingCadenceCountsFortyFiveFramesInsteadOfMedianForty() {
        // Quantized intervals: 30 at 25 ms and 15 at 16.67 ms, totaling 1 s.
        // Inverting the median interval would incorrectly produce 40 fps.
        var counter = SourceFrameRateCounter(startTime: 0)
        var time = 0.0
        for index in 0..<45 {
            counter.record(at: time)
            time += index % 3 == 2 ? 1.0 / 60 : 1.0 / 40
        }
        XCTAssertEqual(time, 1, accuracy: 0.000001)
        XCTAssertEqual(counter.sample(at: time)!, 45, accuracy: 0.000001)
    }

    func testElapsedWindowAndReset() {
        var counter = SourceFrameRateCounter(startTime: 10)
        for index in 0..<90 { counter.record(at: 10 + Double(index) / 45) }
        XCTAssertEqual(counter.sample(at: 12)!, 45, accuracy: 0.000001)
        XCTAssertEqual(counter.sample(at: 13)!, 0)
        counter.reset(at: 20)
        counter.record(at: .nan)
        counter.record(at: 19)
        XCTAssertNil(counter.sample(at: 20))
        counter.record(at: 20.5)
        XCTAssertEqual(counter.sample(at: 21)!, 1)
    }
}
