import Foundation

/// Separate calibration for immediate presentation. Samples are submission-to-
/// presentedTime, not callback arrival. A depth bucket is an app-side observation,
/// never an assertion about WindowServer's internal queue.
public struct UnsyncedPresentationPolicy {
    private var midpointLags: [[Double]] = [[], []]
    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func recordMidpoint(submittedAt: Double, presentedAt: Double, framesAhead: Int) {
        let lag = presentedAt - submittedAt
        guard submittedAt.isFinite, presentedAt.isFinite, lag >= 0, lag < 0.050,
              framesAhead >= 0, framesAhead < 2 else { return }
        midpointLags[framesAhead].append(lag)
        if midpointLags[framesAhead].count > 45 { midpointLags[framesAhead].removeFirst() }
    }

    public func midpointReserve(lead: Double, framesAhead: Int) -> Double {
        guard lead.isFinite, lead > 0 else { return 0 }
        // Do not relax admission while two or more requests are still pending.
        guard framesAhead >= 0, framesAhead < 2 else { return lead }
        let observations = midpointLags[framesAhead].sorted()
        // Warm-up remains conservative under backlog; an empty output queue
        // starts with 8 ms rather than a VSync-derived full submission lead.
        guard observations.count >= 12 else { return framesAhead == 0 ? min(lead, 0.008) : lead }
        let typical = observations[Int(Double(observations.count - 1) * 0.6)]
        // Bounded typical-case admission, with safety headroom. The caller still
        // rechecks expiry after acquisition and prevents sequence overtaking.
        return min(lead, max(0.004, typical + 0.001))
    }
}
