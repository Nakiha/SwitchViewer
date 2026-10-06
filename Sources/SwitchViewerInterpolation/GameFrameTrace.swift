import Foundation

/// Bounded, opt-in timing capture. Callers record numeric fields; encoding and
/// disk output happen off the game and presentation queues in batches.
public final class GameFrameTrace {
    public struct Event: Codable {
        public var traceID: Int = 0
        public let kind: String
        public let sequence: UInt64
        public let time: Double
        public var original: Bool?
        public var multiplier: Int?
        public var phase: Double?
        public var captureID: UInt64?
        public var callbackTime: Double?
        public var pendingPresentation: Int?
        public var pendingGPU: Int?
        public var pendingAcquisition: Int?
        public var overlayHidden: Bool?
        public var windowVisible: Bool?
        public var windowOccluded: Bool?
        public var applicationActive: Bool?
        public var windowFullscreen: Bool?
        public var surfaceWidth: Int?
        public var surfaceHeight: Int?
        public var screenMaximumFPS: Int?
        public var syncEnabled: Bool?
        public var displayID: UInt32?
        public var drawableID: UInt64?
        public var refreshPeriod: Double?
        public var source: Double?
        public var ready: Double?
        public var currentSource: Double?
        public var deadline: Double?
        public var expires: Double?
        public var requested: Double?
        public var submissionReserve: Double?
        public var submissionAdvance: Double?
        public var pacingDelay: Double?
        public var minimumDuration: Double?
        public var gpu: Double?
        public var processing: Double?
        public var algorithm: Double?
        public var reason: String?

        public init(_ kind: String, sequence: UInt64, time: Double) {
            self.kind = kind; self.sequence = sequence; self.time = time
        }
    }
    private let lock = NSLock()
    private let capacity: Int
    private var events: [Event] = []
    private var start: Double = .infinity
    private var end: Double = -.infinity
    private var traceID = 0
    private var lost = 0

    public init(capacity: Int = 4096) { self.capacity = max(1, capacity) }

    @discardableResult
    public func begin(at time: Double, duration: Double = 30) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard time.isFinite, duration.isFinite, duration > 0 else { return traceID }
        traceID += 1
        start = time; end = time + min(60, duration)
        // Keep the preceding batch if the user starts another recording early.
        return traceID
    }

    public func record(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        guard event.time.isFinite, event.time >= start, event.time < end else { return }
        guard events.count < capacity else { lost += 1; return }
        var event = event
        event.traceID = traceID
        events.append(event)
    }

    public func isRecording(at time: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return time >= start && time < end
    }

    public func takeBatch() -> (events: [Event], lost: Int) {
        lock.lock(); defer { lock.unlock() }
        let batch = (events, lost)
        events.removeAll(keepingCapacity: true); lost = 0
        return batch
    }
}
