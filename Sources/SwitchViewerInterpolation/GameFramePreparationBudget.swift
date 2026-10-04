import Foundation

/// CPU work still needed before committing a ready frame. Presentation latency
/// is deliberately excluded: it is handled by pair ownership and the GPU queue.
public struct GameFramePreparationBudget {
    private var acquisitions: [Double] = []
    private var encodings: [Double] = []
    public init() {}
    public mutating func recordAcquisition(_ seconds: Double) { Self.record(seconds, in: &acquisitions) }
    public mutating func recordEncoding(_ seconds: Double) { Self.record(seconds, in: &encodings) }
    private static func record(_ seconds: Double, in samples: inout [Double]) {
        guard seconds.isFinite, seconds >= 0, seconds < 0.050 else { return }
        samples.append(seconds)
        if samples.count > 45 { samples.removeFirst() }
    }
    private func estimate(_ samples: [Double], fallback: Double) -> Double {
        guard samples.count >= 12 else { return fallback }
        let sorted = samples.sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.8)]
    }
    public func reserve(lead: Double, acquired: Bool) -> Double {
        guard lead.isFinite, lead > 0 else { return 0 }
        let encoding = max(0.0005, estimate(encodings, fallback: 0.0005) + 0.00025)
        let acquisition = acquired ? 0 : estimate(acquisitions, fallback: 0.003)
        return min(lead, acquisition + encoding)
    }
}
