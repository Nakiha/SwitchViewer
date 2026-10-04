import XCTest
@testable import SwitchViewerInterpolation

final class GameFramePlayoutTests: XCTestCase {
    func test45FPSOriginalIsQueuedBeforeNextInputDespiteQuantizedCadence() {
        var planner = GameFramePlayoutPlanner()
        var pressure = GameFramePressureController()
        for _ in 0..<30 {
            pressure.recordProcessing(seconds: 0.014)
            pressure.recordDelivery(shown: true)
        }
        for interval in [0.02497, 1.0 / 60, 0.02496, 0.02498, 1.0 / 60] {
            _ = planner.observeInterval(interval)
        }
        let cadence = planner.observeInterval(0.02497)!
        XCTAssertTrue(GameFramePlayoutPlanner.supportsPrequeue(interval: cadence))
        for _ in 0..<60 { _ = pressure.delay(interval: cadence) }
        let delay = pressure.delay(interval: cadence)!
        let plan = planner.prepareOriginal(sourceTime: 1, interval: cadence,
                                           readyTime: 1.002, adaptiveDelay: delay)!
        let submission = plan.originalDeadline - GameFramePlayoutPlanner.submissionLead(interval: cadence)
        // Even the short, quantized input interval arrives after A's submission.
        XCTAssertLessThan(submission, 1 + 1.0 / 60)
        let next = planner.prepareOriginal(sourceTime: 1 + cadence, interval: cadence,
                                           readyTime: 1 + cadence + 0.002, adaptiveDelay: delay)!
        XCTAssertLessThan(1 + cadence + 0.014,
                          next.originalDeadline - GameFramePlayoutPlanner.submissionLead(interval: cadence))
        XCTAssertFalse(GameFramePlayoutPlanner.supportsPrequeue(interval: 1.0 / 60))
        XCTAssertFalse(GameFramePlayoutPlanner.supportsPrequeue(interval: .nan))
    }
    func testCadencePredictionRejectsSingleFrameJitterAndTracksSustainedChange() {
        var planner = GameFramePlayoutPlanner()
        XCTAssertEqual(planner.observeInterval(1.0 / 30)!, 1.0 / 30, accuracy: 0.000001)
        _ = planner.observeInterval(0.025)
        XCTAssertEqual(planner.observeInterval(0.041)!, 1.0 / 30, accuracy: 0.000001)
        _ = planner.observeInterval(1.0 / 30)
        _ = planner.observeInterval(1.0 / 30)
        _ = planner.observeInterval(1.0 / 60)
        _ = planner.observeInterval(1.0 / 60)
        XCTAssertEqual(planner.observeInterval(1.0 / 60)!, 1.0 / 60, accuracy: 0.000001)
        planner.reset()
        XCTAssertEqual(planner.observeInterval(1.0 / 60)!, 1.0 / 60, accuracy: 0.000001)
        XCTAssertNil(planner.observeInterval(.nan))
    }
    func testPreparedOriginalSubmitsBeforeNextInputAndReservesMidpointSlot() {
        let planner = GameFramePlayoutPlanner()
        let interval = 1.0 / 30
        let plan = planner.prepareOriginal(sourceTime: 1, interval: interval, readyTime: 1.003)!
        let lead = GameFramePlayoutPlanner.submissionLead(interval: interval)
        XCTAssertLessThan(plan.originalDeadline - lead, 1 + interval)
        XCTAssertEqual(plan.originalDeadline, 1 + interval * 1.25, accuracy: 0.000001)
        // A 17 ms interpolation job on the next input can still submit before
        // the following original's early submission, keeping presentation order.
        let next = planner.prepareOriginal(sourceTime: 1 + interval, interval: interval, readyTime: 1.037)!
        XCTAssertLessThan(1 + interval + 0.017, next.originalDeadline - lead)
        XCTAssertEqual(plan.midpointDeadline, plan.originalDeadline + interval / 2, accuracy: 0.000001)
        XCTAssertFalse(plan.midpointIsUseful(at: next.originalDeadline))
    }

    func testPredictionDoesNotAccumulateMissedFramesOrAcceptInvalidCadence() {
        let planner = GameFramePlayoutPlanner()
        let late = planner.prepareOriginal(sourceTime: 1, interval: 1.0 / 30, readyTime: 1.1)!
        XCTAssertEqual(late.originalDeadline, 1.12, accuracy: 0.000001)
        let resumed = planner.prepareOriginal(sourceTime: 2, interval: 1.0 / 30, readyTime: 2.001)!
        XCTAssertEqual(resumed.originalDeadline, 2 + 1.25 / 30, accuracy: 0.000001)
        XCTAssertNil(planner.prepareOriginal(sourceTime: 1, interval: .nan, readyTime: 1))
        XCTAssertNil(planner.prepareOriginal(sourceTime: 1, interval: 0.3, readyTime: 1))
        XCTAssertNil(planner.prepareOriginal(sourceTime: 1, interval: 0.03, readyTime: 0.9))
    }

    func testFastInputsLeaveTimeForMidpointRatherThanDroppingEveryResult() {
        let planner = GameFramePlayoutPlanner()
        let interval = 1.0 / 60
        let plan = planner.prepareOriginal(sourceTime: 1, interval: interval, readyTime: 1.002)!
        let next = planner.prepareOriginal(sourceTime: 1 + interval, interval: interval, readyTime: 1.019)!
        let resultReady = 1 + interval + 0.017
        let lead = GameFramePlayoutPlanner.submissionLead(interval: interval)
        XCTAssertEqual(plan.midpointDeadline - (1 + interval), 0.025, accuracy: 0.000001)
        XCTAssertLessThan(resultReady, next.originalDeadline - lead)
        XCTAssertLessThan(resultReady + lead, plan.nextOriginalDeadline)
    }

    func testProcessingPressureReservesSubmissionTimeWithoutAccumulatingBacklog() {
        let planner = GameFramePlayoutPlanner()
        let interval = 1.0 / 30
        let lead = GameFramePlayoutPlanner.submissionLead(interval: interval)
        let plan = planner.prepareOriginal(sourceTime: 1, interval: interval, readyTime: 1.003, processingTime: 0.035)!
        let next = planner.prepareOriginal(sourceTime: 1 + interval, interval: interval, readyTime: 1.037, processingTime: 0.035)!
        XCTAssertLessThan(1 + interval + 0.035, next.originalDeadline - lead)
        XCTAssertLessThan(1 + interval + 0.035 + lead, plan.nextOriginalDeadline)
        let recovered = planner.prepareOriginal(sourceTime: 2, interval: interval, readyTime: 2.003)!
        XCTAssertEqual(recovered.originalDeadline, 2 + interval * 1.25, accuracy: 0.000001)
    }
    func testOriginalDoesNotWaitForInterpolationAndMidpointKeepsItsDeadline() {
        var planner = GameFramePlayoutPlanner()
        let plan = planner.plan(previousTime: 1, currentTime: 1 + 1.0 / 30, readyTime: 1.035)!
        XCTAssertEqual(plan.originalDeadline, 1.035, accuracy: 0.000001)
        XCTAssertEqual(plan.midpointDeadline, 1.035 + 1.0 / 60, accuracy: 0.000001)
        // A 14 ms computation uses the remaining 2.7 ms of the half-frame budget.
        XCTAssertTrue(plan.midpointIsUseful(at: plan.originalDeadline + 0.014))
        // It can be displayed immediately if slightly late, but never in the next pair's slot.
        XCTAssertTrue(plan.midpointIsUseful(at: plan.midpointDeadline + 0.004))
        XCTAssertFalse(plan.midpointIsUseful(at: plan.nextOriginalDeadline))
    }
    func testLateInputResetsQueueAndResetDoesNotRetainPriorDeadlines() {
        var planner = GameFramePlayoutPlanner()
        _ = planner.plan(previousTime: 1, currentTime: 1.033, readyTime: 1.04)
        let late = planner.plan(previousTime: 1.033, currentTime: 1.066, readyTime: 1.12)!
        XCTAssertEqual(late.originalDeadline, 1.12)
        planner.reset()
        let reset = planner.plan(previousTime: 2, currentTime: 2.033, readyTime: 2.034)!
        XCTAssertEqual(reset.originalDeadline, 2.034)
    }
    func testInvalidInputAndExcessiveFutureQueueAreRejectedOrRebased() {
        var planner = GameFramePlayoutPlanner()
        XCTAssertNil(planner.plan(previousTime: 1, currentTime: 1, readyTime: 1))
        XCTAssertNil(planner.plan(previousTime: 1, currentTime: 1.3, readyTime: 1.3))
        XCTAssertNil(planner.plan(previousTime: 1, currentTime: 1.03, readyTime: .nan))
        XCTAssertNil(planner.plan(previousTime: 1, currentTime: 1.03, readyTime: 1.02))
        _ = planner.plan(previousTime: 1, currentTime: 1.04, readyTime: 1.04)
        let fast = planner.plan(previousTime: 1.04, currentTime: 1.05, readyTime: 1.05)!
        XCTAssertEqual(fast.originalDeadline, 1.05)
    }
}
