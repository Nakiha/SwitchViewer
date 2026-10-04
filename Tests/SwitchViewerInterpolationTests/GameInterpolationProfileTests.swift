import XCTest
@testable import SwitchViewerInterpolation

final class GameInterpolationProfileTests: XCTestCase {
    func testLatencyProfileCapsLargeFramesWithoutUpscalingSmallFrames() {
        let cap = GameInterpolationProfile.lowLatency.maximumProxyWidth
        let large = AppleLowLatencyProxySize.best(forWidth: 3024, height: 1898, maximumWidth: cap)
        XCTAssertEqual(large?.width, 1280)
        XCTAssertEqual(large?.height, 720)
        let small = AppleLowLatencyProxySize.best(forWidth: 1100, height: 600, maximumWidth: cap)
        XCTAssertEqual(small?.width, 1024)
        XCTAssertNil(AppleLowLatencyProxySize.best(forWidth: 900, height: 600, maximumWidth: cap))
    }
    func testClarityProfileKeepsExistingResolutionSelection() {
        XCTAssertEqual(AppleLowLatencyProxySize.best(forWidth: 3024, height: 1764,
            maximumWidth: GameInterpolationProfile.clarity.maximumProxyWidth)?.width, 1920)
        XCTAssertEqual(GameInterpolationProfile(rawValue: "lowLatency"), .lowLatency)
        XCTAssertNil(GameInterpolationProfile(rawValue: "invalid"))
    }
}
