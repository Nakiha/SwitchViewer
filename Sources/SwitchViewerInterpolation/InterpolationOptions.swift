import Foundation

public enum InterpolationMultiplier: Int, CaseIterable, Codable {
    case two = 2, four = 4, eight = 8
    public var label: String { "\(rawValue)×" }
    public var configurationLevel: Int { self == .two ? 1 : (self == .four ? 2 : 3) }
    public var phases: [Double] { (1..<rawValue).map { Double($0) / Double(rawValue) } }
}

/// nil retains the existing timing policy. A numeric budget bounds intentional
/// playout buffering relative to unbuffered originals, not hardware/input lag.
public struct InterpolationOptions: Equatable {
    public var multiplier: InterpolationMultiplier
    public private(set) var delayBudgetMilliseconds: Double?
    public init(multiplier: InterpolationMultiplier = .two, delayBudgetMilliseconds: Double? = nil) {
        self.multiplier = multiplier
        self.delayBudgetMilliseconds = delayBudgetMilliseconds.flatMap {
            $0.isFinite ? min(250, max(0, $0)) : nil
        }
    }
    public var usesLegacyTiming: Bool { multiplier == .two && delayBudgetMilliseconds == nil }
    public func boundedDelay(_ seconds: Double) -> Double {
        min(max(0, seconds), (delayBudgetMilliseconds ?? 100) / 1000)
    }
    public static func load(defaults: UserDefaults = .standard, prefix: String) -> Self {
        Self(multiplier: InterpolationMultiplier(rawValue: defaults.integer(forKey: prefix + "Multiplier")) ?? .two,
             delayBudgetMilliseconds: (defaults.object(forKey: prefix + "DelayBudgetMS") as? NSNumber)?.doubleValue)
    }
    public func save(defaults: UserDefaults = .standard, prefix: String) {
        defaults.set(multiplier.rawValue, forKey: prefix + "Multiplier")
        if let delayBudgetMilliseconds { defaults.set(delayBudgetMilliseconds, forKey: prefix + "DelayBudgetMS") }
        else { defaults.removeObject(forKey: prefix + "DelayBudgetMS") }
    }
    public static func from(environment: [String: String]) -> Self {
        Self(multiplier: environment["SWITCHVIEWER_GAME_MULTIPLIER"].flatMap(Int.init).flatMap(InterpolationMultiplier.init(rawValue:)) ?? .two,
             delayBudgetMilliseconds: environment["SWITCHVIEWER_GAME_DELAY_MS"].flatMap(Double.init))
    }
}

public struct InterpolationFramePosition {
    public let phase: Double
    public let sourceInterval: Double
    public init(phase: Double, sourceInterval: Double) { self.phase = phase; self.sourceInterval = sourceInterval }
    public var offsetFromCurrent: Double { (1 - phase) * sourceInterval }
}

/// Per-phase readiness, rather than batch completion, determines needed delay.
/// No job backlog is created here. Slow jobs remain in the estimator unclipped.
public struct MultiFrameDelayController {
    private var required: [Double] = []
    private var learnedDelay: Double?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func record(phase: Double, interval: Double, readySeconds: Double) {
        guard phase > 0, phase < 1, interval.isFinite, interval > 0,
              readySeconds.isFinite, readySeconds >= 0 else { return }
        required.append((1 - phase) * interval + readySeconds + 0.004)
        if required.count > 240 { required.removeFirst(required.count - 240) }
    }
    public mutating func delay(interval: Double, options: InterpolationOptions) -> Double {
        let sorted = required.sorted()
        let wanted = sorted.isEmpty ? interval * 1.25 : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        let previous = learnedDelay ?? wanted
        let next = wanted >= previous ? wanted : max(wanted, previous - 0.00025)
        learnedDelay = options.boundedDelay(next)
        return learnedDelay!
    }
}
