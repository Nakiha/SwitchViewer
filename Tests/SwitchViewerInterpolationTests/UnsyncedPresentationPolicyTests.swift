import XCTest
@testable import SwitchViewerInterpolation

final class UnsyncedPresentationPolicyTests: XCTestCase {
    func testQueuePressureKeepsItsOwnBudgetAndDeepQueueDoesNotRelax() {
        var policy = UnsyncedPresentationPolicy()
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 0), 0.008)
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 1), 0.015)
        for _ in 0..<12 {
            policy.recordMidpoint(submittedAt: 1, presentedAt: 1.006, framesAhead: 0)
            policy.recordMidpoint(submittedAt: 1, presentedAt: 1.018, framesAhead: 1)
        }
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 0), 0.007, accuracy: 1e-9)
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 1), 0.015)
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 2), 0.015)
    }
    func testInvalidAndStallSamplesDoNotPoisonBudgetAndPressureCanRecover() {
        var policy = UnsyncedPresentationPolicy()
        for _ in 0..<12 { policy.recordMidpoint(submittedAt: 1, presentedAt: 1.025, framesAhead: 0) }
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 0), 0.015)
        for _ in 0..<45 { policy.recordMidpoint(submittedAt: 1, presentedAt: 1.005, framesAhead: 0) }
        policy.recordMidpoint(submittedAt: .nan, presentedAt: 1, framesAhead: 0)
        policy.recordMidpoint(submittedAt: 1, presentedAt: 1.2, framesAhead: 0)
        policy.recordMidpoint(submittedAt: 1, presentedAt: 0.9, framesAhead: 0)
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 0), 0.006, accuracy: 1e-9)
        XCTAssertEqual(policy.midpointReserve(lead: 0.003, framesAhead: 0), 0.003)
        policy.reset()
        XCTAssertEqual(policy.midpointReserve(lead: 0.015, framesAhead: 0), 0.008)
    }
}
