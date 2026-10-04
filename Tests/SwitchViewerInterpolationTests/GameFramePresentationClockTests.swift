import XCTest
@testable import SwitchViewerInterpolation

final class GameFramePresentationClockTests: XCTestCase {
    func testPersistentCompositionLagAdvancesRequestWithoutGoingBeforeSubmission() {
        var clock = GameFramePresentationClock()
        let lead = 0.015
        for _ in 0..<20 { clock.record(requestedAt: 1, presentedAt: 1.012, lead: lead) }
        XCTAssertEqual(clock.advance, 0.012, accuracy: 0.000001)
        XCTAssertEqual(clock.requestTime(deadline: 2.030, submittedAt: 2.015, lead: lead), 2.018, accuracy: 0.000001)
        XCTAssertEqual(clock.requestTime(deadline: 2.030, submittedAt: 2.025, lead: lead), 2.025, accuracy: 0.000001)
        XCTAssertEqual(clock.requestTime(deadline: 2.030, submittedAt: 2.020, lead: 0), 2.030, accuracy: 0.000001)
    }

    func testSpikesDoNotMoveClockAndCorrectionIsBoundedAndRecoverable() {
        var clock = GameFramePresentationClock()
        for _ in 0..<5 { clock.record(requestedAt: 1, presentedAt: 1.001, lead: 0.015) }
        clock.record(requestedAt: 1, presentedAt: 1.040, lead: 0.015)
        clock.record(requestedAt: 1, presentedAt: 1.220, lead: 0.015)
        XCTAssertEqual(clock.advance, 0.001, accuracy: 0.000001)
        for _ in 0..<20 { clock.record(requestedAt: 1, presentedAt: 1.030, lead: 0.015) }
        XCTAssertEqual(clock.advance, 0.015, accuracy: 0.000001)
        for _ in 0..<20 { clock.record(requestedAt: 1, presentedAt: 1, lead: 0.015) }
        XCTAssertEqual(clock.advance, 0, accuracy: 0.000001)
        clock.record(requestedAt: .nan, presentedAt: 1, lead: 0.015)
        clock.reset()
        XCTAssertEqual(clock.advance, 0)
    }
    func testMidpointGraceNeedsConsistentOriginalLatenessAndKeepsSafetyMargin() {
        var clock = GameFramePresentationClock()
        for _ in 0..<11 { clock.recordOriginal(deadline: 1, presentedAt: 1.008) }
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.014), 0.014)
        XCTAssertEqual(clock.originalSubmissionAdvance, 0)
        clock.recordOriginal(deadline: 1, presentedAt: 1.008)
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.014), 0.012, accuracy: 0.000001)
        XCTAssertEqual(clock.originalSubmissionAdvance, 0.004, accuracy: 0.000001)
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.004), 0.003, accuracy: 0.000001)
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0), 0)
        for _ in 0..<30 { clock.recordOriginal(deadline: 1, presentedAt: 1.0005) }
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.014), 0.014)
        clock.reset()
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.014), 0.014)
        XCTAssertEqual(clock.originalSubmissionAdvance, 0)
    }

    func testEarlyOriginalsAndStallsDoNotAuthorizeMidpointGrace() {
        var clock = GameFramePresentationClock()
        for _ in 0..<30 { clock.recordOriginal(deadline: 1, presentedAt: 1.080) }
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.014), 0.014)
        for _ in 0..<30 { clock.recordOriginal(deadline: 1, presentedAt: 0.999) }
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.014), 0.014)
        clock.recordOriginal(deadline: .nan, presentedAt: 1.008)
        XCTAssertEqual(clock.midpointSubmissionReserve(lead: 0.014), 0.014)
        XCTAssertEqual(clock.originalSubmissionAdvance, 0)
    }

}
