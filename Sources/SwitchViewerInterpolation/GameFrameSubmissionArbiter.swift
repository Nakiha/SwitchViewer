import Foundation

/// Main-queue pair ownership. A ready midpoint keeps its place while acquiring
/// a drawable, but may hold the following original for at most 1 ms past its
/// old submission slot. Unfinished interpolation never earns this extension.
public struct GameFrameSubmissionArbiter {
    private var ready: Set<UInt64> = []
    public init() {}
    public mutating func reset() { ready.removeAll() }
    public mutating func registerMidpoint(_ sequence: UInt64) { ready.insert(sequence) }
    public mutating func resolveMidpoint(_ sequence: UInt64) { ready.remove(sequence) }
    public func originalWaitUntil(sequence: UInt64, pendingMidpoint: UInt64?, nominal: Double,
                                  expires: Double, now: Double) -> Double? {
        guard sequence > 0, pendingMidpoint == sequence - 1,
              nominal.isFinite, expires.isFinite, now.isFinite else { return nil }
        let limit = min(expires, nominal + (ready.contains(sequence - 1) ? 0.001 : 0))
        return now < limit ? limit : nil
    }
}
