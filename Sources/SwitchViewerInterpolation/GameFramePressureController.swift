import Foundation

/// Bounded feedback for original-frame delay. Processing and delivery are
/// separate: a busy algorithm cannot recover throughput just by buffering more.
public struct GameFramePressureController {
    private var durations: [Double] = []
    private var deliveries: [Bool] = []
    private var currentDelay: Double?
    private var lastInterval: Double?

    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func recordProcessing(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        durations.append(min(0.080, seconds))
        if durations.count > 30 { durations.removeFirst() }
    }

    public mutating func recordDelivery(shown: Bool) {
        deliveries.append(shown)
        if deliveries.count > 30 { deliveries.removeFirst() }
    }

    public var deliveryRate: Double? {
        guard !deliveries.isEmpty else { return nil }
        return Double(deliveries.filter { $0 }.count) / Double(deliveries.count)
    }

    public var processingBudget: Double {
        guard !durations.isEmpty else { return 0.017 }
        let sorted = durations.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.85)) - 1)]
    }

    public mutating func delay(interval: Double) -> Double? {
        guard interval.isFinite, interval > 0, interval < 0.2 else { return nil }
        let lower = interval + 0.001
        let upper = max(lower, min(0.100, interval * 2))
        if currentDelay == nil || lastInterval.map({ abs($0 - interval) > $0 * 0.25 }) == true {
            currentDelay = min(upper, max(lower, interval * 1.25))
        }
        lastInterval = interval
        // Require enough feedback before reacting to a short burst of misses.
        let missMargin: Double
        if deliveries.count >= 12, let rate = deliveryRate {
            missMargin = rate < 0.8 ? 0.006 : (rate < 0.9 ? 0.003 : 0.001)
        } else { missMargin = 0.002 }
        let target = min(upper, max(lower,
            processingBudget + GameFramePlayoutPlanner.submissionLead(interval: interval) + missMargin))
        let old = currentDelay!
        // Grow faster than we shrink, but never shift a slot by a whole refresh.
        let step = target > old ? min(0.002, target - old) : max(-0.00025, target - old)
        currentDelay = min(upper, max(lower, old + step))
        return currentDelay
    }
}
