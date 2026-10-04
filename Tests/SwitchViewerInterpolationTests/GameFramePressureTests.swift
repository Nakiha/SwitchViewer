import XCTest
@testable import SwitchViewerInterpolation

final class GameFramePressureTests: XCTestCase {
    func testLowLoadReducesDelayAndSustainedPressureIncreasesItWithinBounds() {
        var controller = GameFramePressureController()
        let interval = 1.0 / 30
        for _ in 0..<30 { controller.recordProcessing(seconds: 0.008); controller.recordDelivery(shown: true) }
        let initial = controller.delay(interval: interval)!
        var low = initial
        for _ in 0..<60 { low = controller.delay(interval: interval)! }
        XCTAssertLessThan(low, initial)
        for _ in 0..<30 { controller.recordProcessing(seconds: 0.080); controller.recordDelivery(shown: false) }
        var high = low
        for _ in 0..<60 {
            let next = controller.delay(interval: interval)!
            XCTAssertLessThanOrEqual(next - high, 0.002001)
            XCTAssertLessThanOrEqual(next, interval * 2 + 0.000001)
            high = next
        }
        XCTAssertGreaterThan(high, low + 0.020)
    }

    func testRecoveryIsSlowerThanPressureResponseAndClearsOldWindow() {
        var controller = GameFramePressureController()
        for _ in 0..<30 { controller.recordProcessing(seconds: 0.060); controller.recordDelivery(shown: false) }
        for _ in 0..<30 { _ = controller.delay(interval: 1.0 / 30) }
        let high = controller.delay(interval: 1.0 / 30)!
        for _ in 0..<30 { controller.recordProcessing(seconds: 0.008); controller.recordDelivery(shown: true) }
        let recovering = controller.delay(interval: 1.0 / 30)!
        XCTAssertLessThan(recovering, high)
        XCTAssertLessThanOrEqual(high - recovering, 0.000251)
        for _ in 0..<160 { _ = controller.delay(interval: 1.0 / 30) }
        XCTAssertLessThan(controller.delay(interval: 1.0 / 30)!, 0.035)
        XCTAssertEqual(controller.deliveryRate!, 1)
    }

    func testIsolatedSpikeAndMissDoNotRaiseBudget() {
        var controller = GameFramePressureController()
        for _ in 0..<29 { controller.recordProcessing(seconds: 0.010); controller.recordDelivery(shown: true) }
        controller.recordProcessing(seconds: 0.080)
        controller.recordDelivery(shown: false)
        XCTAssertEqual(controller.processingBudget, 0.010)
        for _ in 0..<60 { _ = controller.delay(interval: 1.0 / 30) }
        XCTAssertLessThan(controller.delay(interval: 1.0 / 30)!, 0.035)
    }

    func testMissedDisplayFeedbackAddsHeadroomEvenWithSameComputeCost() {
        var good = GameFramePressureController(), bad = GameFramePressureController()
        for _ in 0..<30 {
            good.recordProcessing(seconds: 0.020); bad.recordProcessing(seconds: 0.020)
            good.recordDelivery(shown: true); bad.recordDelivery(shown: false)
        }
        for _ in 0..<60 { _ = good.delay(interval: 1.0 / 30); _ = bad.delay(interval: 1.0 / 30) }
        XCTAssertGreaterThan(bad.delay(interval: 1.0 / 30)!, good.delay(interval: 1.0 / 30)! + 0.003)
    }

    func testInvalidSamplesAndResetDoNotPoisonFutureSessions() {
        var controller = GameFramePressureController()
        controller.recordProcessing(seconds: .nan); controller.recordProcessing(seconds: -1)
        XCTAssertEqual(controller.processingBudget, 0.017)
        XCTAssertNil(controller.delay(interval: .nan))
        XCTAssertNil(controller.delay(interval: 0))
        XCTAssertGreaterThanOrEqual(controller.delay(interval: 0.15)!, 0.151)
        for _ in 0..<30 { controller.recordProcessing(seconds: 0.080); controller.recordDelivery(shown: false) }
        controller.reset()
        XCTAssertNil(controller.deliveryRate)
        XCTAssertLessThan(controller.delay(interval: 1.0 / 30)!, 0.045)
    }
}
