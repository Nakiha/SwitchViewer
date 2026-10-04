import Foundation

/// Account for the observed gap between a requested presentation and actual
/// composition. This changes the request time, never frame order or submission.
public struct GameFramePresentationClock {
    private var lags: [Double] = []
    private var originalLateness: [Double] = []
    public private(set) var advance: Double = 0

    public init() {}
    public mutating func reset() { self = Self() }

    public func requestTime(deadline: Double, submittedAt: Double, lead: Double) -> Double {
        max(submittedAt, deadline - min(advance, max(0, lead)))
    }

    /// Nominal expiry assumes the next original meets its target. Reclaim at
    /// most 2 ms only after originals consistently display later than that
    /// target. Keep a 1 ms safety margin and never change original scheduling.
    public func midpointSubmissionReserve(lead: Double) -> Double {
        guard lead.isFinite, lead > 0 else { return 0 }
        guard originalLateness.count >= 12 else { return lead }
        let sorted = originalLateness.sorted()
        let lowerLateness = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let grace = min(0.002, lead / 4, max(0, lowerLateness - 0.001))
        return lead - grace
    }

    /// Reclaim only observed presentation slack, with a 2 ms margin. The caller
    /// must wait for the preceding midpoint before advancing an original.
    public var originalSubmissionAdvance: Double {
        guard originalLateness.count >= 12 else { return 0 }
        let sorted = originalLateness.sorted()
        let lowerLateness = sorted[Int(Double(sorted.count - 1) * 0.1)]
        return min(0.004, max(0, lowerLateness - 0.002))
    }

    public mutating func recordOriginal(deadline: Double, presentedAt: Double) {
        guard deadline.isFinite, presentedAt.isFinite else { return }
        let lateness = presentedAt - deadline
        guard abs(lateness) < 0.050 else { return } // Do not learn from a stall.
        originalLateness.append(lateness)
        if originalLateness.count > 30 { originalLateness.removeFirst() }
    }

    public mutating func record(requestedAt: Double, presentedAt: Double, lead: Double) {
        guard requestedAt.isFinite, presentedAt.isFinite, lead.isFinite,
              lead > 0, presentedAt >= requestedAt else { return }
        // Discard stalls instead of turning them into permanent compensation.
        let lag = presentedAt - requestedAt
        guard lag < 0.050 else { return }
        lags.append(lag)
        if lags.count > 5 { lags.removeFirst() }
        guard lags.count == 5 else { return }
        let target = min(lead, lags.sorted()[2])
        advance += min(0.002, max(-0.002, target - advance))
        advance = min(lead, max(0, advance))
    }
}
