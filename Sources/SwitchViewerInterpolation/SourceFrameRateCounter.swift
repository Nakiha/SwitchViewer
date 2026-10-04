import Foundation

/// Counts source submissions over elapsed wall time, rather than inverting a
/// median cadence interval (which is biased when frame intervals alternate).
public struct SourceFrameRateCounter {
    private var windowStart: Double
    private var count = 0

    public init(startTime: Double) { windowStart = startTime }

    public mutating func record(at time: Double) {
        guard time.isFinite, time >= windowStart else { return }
        count += 1
    }

    public mutating func sample(at time: Double) -> Double? {
        let elapsed = time - windowStart
        guard time.isFinite, elapsed.isFinite, elapsed > 0 else { return nil }
        let rate = Double(count) / elapsed
        reset(at: time)
        return rate
    }

    public mutating func reset(at time: Double) {
        windowStart = time
        count = 0
    }
}
