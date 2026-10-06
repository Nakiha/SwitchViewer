import Foundation
import CoreFoundation
import GameConfigurationNotify

/// One atomic configuration per launch. Notifications carry no files or game-container paths.
public struct GameRuntimeConfiguration: Equatable {
    public var interpolation: InterpolationOptions
    public var profile: GameInterpolationProfile
    public var displaySync: Bool
    public var cadence: GamePresentationCadence
    public init(interpolation: InterpolationOptions, profile: GameInterpolationProfile,
                displaySync: Bool, cadence: GamePresentationCadence) {
        self.interpolation = .init(multiplier: interpolation.multiplier,
            delayBudgetMilliseconds: interpolation.delayBudgetMilliseconds.map { ($0 * 100).rounded() / 100 })
        self.profile = profile
        self.displaySync = displaySync; self.cadence = cadence
    }
    public static func from(environment: [String: String]) -> Self {
        .init(interpolation: .from(environment: environment),
              profile: GameInterpolationProfile(rawValue: environment["SWITCHVIEWER_GAME_PROFILE"] ?? "") ?? .clarity,
              displaySync: environment["SWITCHVIEWER_GAME_DISPLAY_SYNC"] != "0",
              cadence: .init(configuration: environment["SWITCHVIEWER_GAME_CADENCE"]))
    }
    public var summary: String {
        let budget = interpolation.delayBudgetMilliseconds.map { String(format: "%g ms", $0) } ?? "自动延迟"
        return "\(interpolation.multiplier.label) · \(profile == .lowLatency ? "720p" : "1080p") · \(budget)"
    }
    /// Version 1: request ID + complete settings, budget in hundredths of a millisecond.
    public func encoded(requestID: UInt32) -> UInt64 {
        let multiplier = UInt64(InterpolationMultiplier.allCases.firstIndex(of: interpolation.multiplier)!)
        let budget = interpolation.delayBudgetMilliseconds.map { UInt64(($0 * 100).rounded()) } ?? 32767
        let fields = multiplier | (profile == .lowLatency ? 4 : 0) | (displaySync ? 8 : 0)
            | (cadence == .uniform ? 16 : 0) | (budget << 5) | (1 << 20)
        return (UInt64(requestID) << 32) | fields
    }
    public static func decode(_ value: UInt64) -> (requestID: UInt32, configuration: Self)? {
        guard (value >> 20) & 15 == 1, value & 0xff000000 == 0 else { return nil }
        let index = Int(value & 3), budget = (value >> 5) & 32767
        guard InterpolationMultiplier.allCases.indices.contains(index), budget <= 25000 || budget == 32767 else { return nil }
        return (UInt32(value >> 32), .init(
            interpolation: .init(multiplier: InterpolationMultiplier.allCases[index],
                                 delayBudgetMilliseconds: budget == 32767 ? nil : Double(budget) / 100),
            profile: value & 4 == 0 ? .clarity : .lowLatency,
            displaySync: value & 8 != 0, cadence: value & 16 == 0 ? .lowLatency : .uniform))
    }
}

/// Both ends retain a notify token, keeping the state alive until the game exits.
/// Access each instance on its owning serial queue; callers handle acknowledgements.
public final class GameConfigurationChannel {
    public let name: String
    private var token: Int32 = -1
    public init(identifier: String) throws {
        guard let uuid = UUID(uuidString: identifier) else { throw NSError(domain: "SwitchViewer.Configuration", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的配置通道"]) }
        name = "com.zhu.switchviewer.configuration." + uuid.uuidString
        let code = SVConfigurationRegister(name, &token)
        guard code == 0 else { throw NSError(domain: "SwitchViewer.Configuration", code: Int(code)) }
    }
    deinit { if token >= 0 { SVConfigurationCancel(token) } }
    public func read() -> (requestID: UInt32, configuration: GameRuntimeConfiguration)? {
        var value: UInt64 = 0
        guard SVConfigurationRead(token, &value) == 0 else { return nil }
        return GameRuntimeConfiguration.decode(value)
    }
    public func send(_ configuration: GameRuntimeConfiguration, requestID: UInt32) throws {
        let code = SVConfigurationWrite(token, configuration.encoded(requestID: requestID))
        guard code == 0 else { throw NSError(domain: "SwitchViewer.Configuration", code: Int(code)) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString), nil, nil, true)
    }
    public func observe(callback: CFNotificationCallback) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil,
            callback, name as CFString, nil, .deliverImmediately)
    }
}
