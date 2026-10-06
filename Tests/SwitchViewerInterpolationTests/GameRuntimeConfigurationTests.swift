import XCTest
@testable import SwitchViewerInterpolation

final class GameRuntimeConfigurationTests: XCTestCase {
    func testAtomicConfigurationRoundTripsAllControlsAndBudgets() {
        for multiplier in InterpolationMultiplier.allCases {
            for budget: Double? in [nil, 0, 0.01, 60.25, 250] {
                for profile in GameInterpolationProfile.allCases {
                    for sync in [false, true] {
                        for cadence in GamePresentationCadence.allCases {
                            let config = GameRuntimeConfiguration(interpolation: .init(multiplier: multiplier, delayBudgetMilliseconds: budget),
                                profile: profile, displaySync: sync, cadence: cadence)
                            let decoded = GameRuntimeConfiguration.decode(config.encoded(requestID: UInt32.max))
                            XCTAssertEqual(decoded?.requestID, UInt32.max)
                            XCTAssertEqual(decoded?.configuration, config)
                        }
                    }
                }
            }
        }
    }
    func testMalformedAndUnknownProtocolsAreRejected() {
        let config = GameRuntimeConfiguration.from(environment: [:])
        let value = config.encoded(requestID: 1)
        XCTAssertNil(GameRuntimeConfiguration.decode(0))
        XCTAssertNil(GameRuntimeConfiguration.decode(value | 3)) // Unsupported factor.
        XCTAssertNil(GameRuntimeConfiguration.decode(value | (1 << 24))) // Reserved fields.
        XCTAssertNil(GameRuntimeConfiguration.decode(value ^ (3 << 20))) // Unknown version.
        let invalidBudget = (value & ~(UInt64(32767) << 5)) | (30000 << 5)
        XCTAssertNil(GameRuntimeConfiguration.decode(invalidBudget))
        XCTAssertThrowsError(try GameConfigurationChannel(identifier: "not-a-launch-uuid"))
    }
    func testChannelCoalescesWithoutMixingSettingsOrOtherLaunches() throws {
        let id = UUID().uuidString
        let writer = try GameConfigurationChannel(identifier: id)
        let reader = try GameConfigurationChannel(identifier: id)
        let other = try GameConfigurationChannel(identifier: UUID().uuidString)
        var config = GameRuntimeConfiguration.from(environment: [:])
        try writer.send(config, requestID: 1)
        config.interpolation = .init(multiplier: .eight, delayBudgetMilliseconds: 0)
        config.profile = .lowLatency; config.displaySync = false; config.cadence = .lowLatency
        try writer.send(config, requestID: 2)
        XCTAssertEqual(reader.read()?.requestID, 2)
        XCTAssertEqual(reader.read()?.configuration, config)
        XCTAssertNil(other.read())
    }
    func testReducingMultiplierKeepsFrameIDsForwardAndLeavesPhaseSlotsFree() {
        var sequence = GameFrameSequence()
        XCTAssertEqual(sequence.next(multiplier: .two), 2)
        XCTAssertEqual(sequence.next(multiplier: .two), 4)
        var last: UInt64 = 4, previousFactor: UInt64 = 2
        for multiplier in [InterpolationMultiplier.eight, .two, .four, .eight, .two] {
            let next = sequence.next(multiplier: multiplier)
            // Retired callbacks may still carry old phase IDs after cancellation.
            // New originals must advance past the whole old group's reservation.
            XCTAssertGreaterThanOrEqual(next, last + previousFactor)
            XCTAssertEqual(next % UInt64(multiplier.rawValue), 0)
            let following = sequence.next(multiplier: multiplier)
            XCTAssertGreaterThan(following, next + UInt64(multiplier.rawValue - 1))
            last = following; previousFactor = UInt64(multiplier.rawValue)
        }
    }
}
