import XCTest
@testable import SwitchViewerInterpolation

final class GamePresentationCadenceTests: XCTestCase {
    func testMissingOrUnknownConfigurationDefaultsToUniform() {
        XCTAssertEqual(GamePresentationCadence(configuration: nil), .uniform)
        XCTAssertEqual(GamePresentationCadence(configuration: "invalid"), .uniform)
        XCTAssertEqual(GamePresentationCadence(configuration: "lowLatency"), .lowLatency)
        XCTAssertEqual(GamePresentationCadence(configuration: "uniform"), .uniform)
        XCTAssertEqual(GamePresentationCadence.allCases.map(\.label), ["响应速度优先", "帧间隔均匀优先"])
    }
}
