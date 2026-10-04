import Foundation

/// Small CPU submission phase correction driven by adjacent midpoint/original
/// presentedTime, rather than assuming commit spacing equals display spacing.
public struct UnsyncedCadenceController {
    private var previousSequence: UInt64 = 0
    private var previousTime: Double = 0
    private var gaps: [Double] = []
    public private(set) var delay: Double = 0
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func record(sequence: UInt64, presentedAt time: Double) {
        guard time.isFinite, time > 0, sequence > previousSequence, time > previousTime else { return }
        defer { previousSequence = sequence; previousTime = time }
        guard sequence % 2 == 0, previousSequence == sequence - 1 else { return }
        let gap = time - previousTime
        guard gap < 0.050 else { return } // A visibility/stall gap is not cadence evidence.
        gaps.append(gap)
        if gaps.count > 30 { gaps.removeFirst() }
        guard gaps.count >= 12 else { return }
        let tightFraction = Double(gaps.filter { $0 < 0.003 }.count) / Double(gaps.count)
        let median = gaps.sorted()[gaps.count / 2]
        if tightFraction >= 0.35 && median < 0.004 {
            delay = min(0.004, delay + 0.00025)
        } else if median > 0.006 {
            delay = max(0, delay - 0.000125)
        }
    }
    public func submissionDelay(interval: Double, nominal: Double, expires: Double) -> Double {
        guard interval.isFinite, interval > 0, nominal.isFinite, expires.isFinite else { return 0 }
        return min(delay, interval / 4, max(0, expires - nominal - 0.001))
    }
}
