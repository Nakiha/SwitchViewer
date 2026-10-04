import Foundation

/// Bounded playout storage. Late interpolation must never rewind displayed media.
/// Reset invalidates asynchronous results from the previous capture session.
public final class TimedFrameQueue<Frame> {
    public struct Entry {
        public let frame: Frame
        public let mediaTime: Double
        public let displayTime: Double
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []
    private var lastMediaTime = -Double.infinity
    private var currentGeneration: UInt64 = 0

    public init(capacity: Int = 8) { self.capacity = max(1, capacity) }

    public var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return currentGeneration
    }

    @discardableResult
    public func reset() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        lastMediaTime = -Double.infinity
        currentGeneration &+= 1
        return currentGeneration
    }

    @discardableResult
    public func enqueue(_ frame: Frame, mediaTime: Double, displayTime: Double,
                        generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == currentGeneration, mediaTime.isFinite, displayTime.isFinite,
              mediaTime > lastMediaTime else { return false }
        entries.removeAll { $0.mediaTime == mediaTime }
        entries.append(Entry(frame: frame, mediaTime: mediaTime, displayTime: displayTime))
        entries.sort { $0.mediaTime < $1.mediaTime }
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        return true
    }

    public func take(at displayTime: Double) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard displayTime.isFinite,
              let index = entries.lastIndex(where: { $0.displayTime <= displayTime }) else { return nil }
        let entry = entries[index]
        entries.removeFirst(index + 1)
        lastMediaTime = entry.mediaTime
        return entry
    }
}
