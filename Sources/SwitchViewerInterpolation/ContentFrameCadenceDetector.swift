import Foundation

/// Estimates observed content updates without assuming a fixed capture clock.
/// A duplicate must not advance the last distinct frame's timestamp.
public final class ContentFrameCadenceDetector {
    public struct Result {
        public let isDuplicate: Bool
        public let shouldInterpolate: Bool
        public let updateInterval: Double?
        public let observedFPS: Double?
        public let isDiscontinuity: Bool
    }

    private var lastSignature: DisplayFrameSignature?
    private var lastUpdateTime: Double?
    private var intervals: [Double] = []
    public init() {}

    public func reset() {
        lastSignature = nil
        lastUpdateTime = nil
        intervals.removeAll(keepingCapacity: true)
    }

    public func observe(signature: DisplayFrameSignature?, time: Double) -> Result {
        guard time.isFinite else { reset(); return result(discontinuity: true) }
        if let previousTime = lastUpdateTime, time <= previousTime {
            reset()
            lastSignature = signature
            lastUpdateTime = time
            return result(discontinuity: true)
        }
        if let signature, signature == lastSignature {
            return result(duplicate: true)
        }
        let previousSignature = lastSignature
        let interval = lastUpdateTime.map { time - $0 }
        lastSignature = signature
        lastUpdateTime = time
        guard let interval else { return result() }
        let sameFormat = previousSignature == nil || signature == nil ||
            (previousSignature!.width == signature!.width &&
             previousSignature!.height == signature!.height &&
             previousSignature!.pixelFormat == signature!.pixelFormat)
        // Do not warp across a pause, time discontinuity, or a format change.
        guard sameFormat, interval >= 1.0 / 240, interval <= 0.15 else {
            intervals.removeAll(keepingCapacity: true)
            return result(interval: interval, discontinuity: true)
        }
        intervals.append(interval)
        if intervals.count > 24 { intervals.removeFirst() }
        var sceneCut = false
        if let a = previousSignature?.cadenceLumaSamples, let b = signature?.cadenceLumaSamples,
           !a.isEmpty, a.count == b.count {
            let difference = zip(a, b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) }
                / Double(a.count) / 255
            sceneCut = difference > 0.35
        }
        return result(interpolate: !sceneCut, interval: interval, discontinuity: sceneCut)
    }

    private func result(duplicate: Bool = false, interpolate: Bool = false,
                        interval: Double? = nil, discontinuity: Bool = false) -> Result {
        let fps = intervals.count >= 4
            ? Double(intervals.count) / intervals.reduce(0, +) : nil
        return Result(isDuplicate: duplicate, shouldInterpolate: interpolate,
                      updateInterval: interval, observedFPS: fps, isDiscontinuity: discontinuity)
    }
}
