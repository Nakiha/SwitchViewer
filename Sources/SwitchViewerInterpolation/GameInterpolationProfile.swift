import Foundation

/// Original frames keep their captured resolution in either profile. Only the
/// temporal model's proxy and generated midpoint resolution change.
public enum GameInterpolationProfile: String, CaseIterable {
    case clarity
    case lowLatency
    public var maximumProxyWidth: Int { self == .lowLatency ? 1280 : 1920 }
}
