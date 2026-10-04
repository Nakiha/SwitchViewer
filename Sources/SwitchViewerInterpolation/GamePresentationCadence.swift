import Foundation

/// Explicitly separates response time from visibility of each generated frame.
/// Neither mode changes the captured or interpolation resolution.
public enum GamePresentationCadence: String, CaseIterable {
    case lowLatency
    case uniform
    public init(configuration: String?) { self = Self(rawValue: configuration ?? "") ?? .uniform }
    public var label: String { self == .uniform ? "帧间隔均匀优先" : "响应速度优先" }
}
