import Foundation

/// Predict display slots before the next input arrives, or anchor them to input
/// readiness during warm-up. Results never extend their own midpoint deadline.
public struct GameFramePlayoutPlanner {
    public struct Plan {
        public let originalDeadline: Double
        public let midpointDeadline: Double
        public let nextOriginalDeadline: Double
        public let interval: Double

        public func midpointIsUseful(at time: Double) -> Bool {
            time.isFinite && time < nextOriginalDeadline
        }
    }
    private var nextOriginalDeadline: Double?
    private var observedIntervals: [Double] = []
    public init() {}
    public mutating func reset() { nextOriginalDeadline = nil; observedIntervals.removeAll() }

    /// Cover 45 fps, including the 16.7 / 25 ms cadence produced by a 120 Hz
    /// display. Leave the higher-rate parallel path unchanged for now.
    public static func supportsPrequeue(interval: Double) -> Bool {
        interval.isFinite && interval >= 1.0 / 50 && interval < 0.2
    }

    /// Do not let a single early/late input move a prequeued frame across its
    /// neighbour's slot. A cadence change is accepted after a majority of inputs.
    public mutating func observeInterval(_ interval: Double) -> Double? {
        guard interval.isFinite, interval > 0, interval < 0.2 else { return nil }
        observedIntervals.append(interval)
        if observedIntervals.count > 5 { observedIntervals.removeFirst() }
        let sorted = observedIntervals.sorted()
        return sorted[sorted.count / 2]
    }

    /// Prepare this original while the following input is still being rendered.
    /// At least a quarter interval of headroom keeps midpoint work ahead of the
    /// next original submission. Fast inputs reserve a 25 ms midpoint budget;
    /// otherwise a shorter original delay would discard nearly every midpoint.
    /// Each prediction is anchored to its input, so missed frames cannot build a queue.
    public func prepareOriginal(sourceTime: Double, interval: Double, readyTime: Double,
                                processingTime: Double = 0.017, adaptiveDelay: Double? = nil) -> Plan? {
        guard sourceTime.isFinite, interval.isFinite, readyTime.isFinite, processingTime.isFinite,
              processingTime >= 0,
              interval > 0, interval < 0.2, readyTime >= sourceTime else { return nil }
        if let adaptiveDelay, !adaptiveDelay.isFinite || adaptiveDelay < interval { return nil }
        let cadenceDelay = interval + max(interval / 4, 0.025 - interval / 2)
        // Under GPU load, retain enough time for the observed interpolation job
        // to submit before the following original, instead of losing all midpoints.
        let delay = adaptiveDelay ?? max(cadenceDelay, processingTime + Self.submissionLead(interval: interval) + 0.002)
        let start = max(sourceTime + delay, readyTime + Self.submissionLead(interval: interval))
        return Plan(originalDeadline: start, midpointDeadline: start + interval / 2,
                    nextOriginalDeadline: start + interval, interval: interval)
    }

    public static func submissionLead(interval: Double) -> Double {
        min(0.020, max(0, interval * 0.6))
    }

    public mutating func plan(previousTime: Double, currentTime: Double, readyTime: Double) -> Plan? {
        let interval = currentTime - previousTime
        guard previousTime.isFinite, currentTime.isFinite, readyTime.isFinite,
              interval > 0, interval < 0.2, readyTime >= currentTime else { return nil }
        let scheduled = nextOriginalDeadline ?? readyTime
        let start = scheduled > readyTime + interval / 2 ? readyTime : max(readyTime, scheduled)
        nextOriginalDeadline = start + interval
        return Plan(originalDeadline: start, midpointDeadline: start + interval / 2,
                    nextOriginalDeadline: start + interval, interval: interval)
    }
}
