import XCTest
@testable import SwitchViewerInterpolation

final class GameFramePresentationPolicyTests: XCTestCase {
    func testPreparedPairAdmissionPreservesOrderAndExpiryWithoutReservingDisplayTail() {
        var policy = GameFramePresentationPolicy()
        var options = GameFramePresentationPolicy.Options()
        options.immediate = true; options.preparationAdmission = true
        let middle = policy.plan(sequence: 3, original: false, target: 1.01, expires: 1.022,
                                 interval: 1 / 45, prequeued: true, options: options)
        // Two pending presentation callbacks alone must not discard a ready frame.
        XCTAssertNil(policy.initialRejection(middle, at: 1.010, context: context(ahead: 2)))
        XCTAssertEqual(policy.finalRejection(middle, at: 1.019, framesAhead: 2), .dropPastExpiry)
        XCTAssertNil(policy.finalRejection(middle, at: 1.019, framesAhead: 2, prepared: true))
        XCTAssertEqual(policy.finalRejection(middle, at: 1.022, framesAhead: 0, prepared: true), .dropPastExpiry)
        policy.submitted(4)
        XCTAssertEqual(policy.acquisitionRejection(middle, at: 1.011, context: context()), .dropStaleSequence)
    }
    private func context(ahead: Int = 0, generation: Bool = true, active: Bool = true) -> GameFramePresentationPolicy.Context {
        .init(active: active, generationMatches: generation, outputReady: true, retryAfter: 0, framesAhead: ahead)
    }
    func testQueuePressureIsRecheckedBeforeCommitAndCannotRejectNextOriginal() {
        let policy = GameFramePresentationPolicy()
        var options = GameFramePresentationPolicy.Options()
        options.immediate = true; options.adaptiveAdmission = true
        let middle = policy.plan(sequence: 1, original: false, target: 1.01, expires: 1.025,
                                 interval: 1 / 45, prequeued: true, options: options)
        XCTAssertNil(policy.initialRejection(middle, at: 1.012, context: context()))
        XCTAssertEqual(policy.finalRejection(middle, at: 1.012, framesAhead: 2), .dropPastExpiry)
        let original = policy.plan(sequence: 2, original: true, target: 1.01, expires: 1.025,
                                   interval: 1 / 45, prequeued: true, options: options)
        XCTAssertNil(policy.finalRejection(original, at: 1.012, framesAhead: 2))
    }
    func testDelayedAcquisitionCannotCommitOldOutOfOrderExpiredOrPausedWork() {
        var policy = GameFramePresentationPolicy()
        let plan = policy.plan(sequence: 3, original: false, target: 1, expires: 1.02,
                               interval: 0.02, prequeued: false, options: .init())
        XCTAssertEqual(policy.acquisitionRejection(plan, at: 1, context: context(generation: false)), .dropStaleEpoch)
        XCTAssertEqual(policy.acquisitionRejection(plan, at: 1, context: context(active: false)), .dropPaused)
        XCTAssertEqual(policy.acquisitionRejection(plan, at: 1.02, context: context()), .dropExpired)
        policy.submitted(4)
        XCTAssertEqual(policy.acquisitionRejection(plan, at: 1, context: context()), .dropStaleSequence)
        policy.reset(keepingSubmissionOrder: true)
        XCTAssertEqual(policy.lastSubmittedSequence, 4)
        policy.reset()
        XCTAssertNil(policy.acquisitionRejection(plan, at: 1, context: context()))
    }
    func testOriginalAdvanceNeverChangesTargetsExpiryOrMidpointSubmissionSlot() {
        var policy = GameFramePresentationPolicy()
        var options = GameFramePresentationPolicy.Options(); options.immediate = true
        for i in 1...30 {
            let target = Double(i)
            let plan = policy.plan(sequence: UInt64(i * 2), original: true, target: target,
                                   expires: target + 0.022, interval: 0.022, prequeued: true, options: options)
            policy.presented(plan, submittedAt: target - 0.010, requestedAt: target - 0.010,
                             presentedAt: target + 0.010, framesAhead: 0)
        }
        let a = policy.plan(sequence: 62, original: true, target: 31, expires: 31.022,
                            interval: 0.022, prequeued: true, options: options)
        let m = policy.plan(sequence: 61, original: false, target: 31, expires: 31.022,
                            interval: 0.022, prequeued: true, options: options)
        XCTAssertEqual(a.advance, 0.004)
        XCTAssertEqual(m.advance, 0)
        XCTAssertEqual(a.target, m.target)
        XCTAssertEqual(a.expires, m.expires)
        XCTAssertEqual(a.nominalSubmissionTime, m.submissionTime)
        XCTAssertEqual(policy.requestTime(a, submittedAt: 30.9), 30.9)
    }
    func testStallFeedbackDoesNotTurnIntoPermanentPresentationAdvance() {
        var policy = GameFramePresentationPolicy()
        for i in 1...30 {
            let plan = policy.plan(sequence: UInt64(i * 2), original: true, target: Double(i),
                                   expires: Double(i) + 0.02, interval: 0.02, prequeued: true, options: .init())
            policy.presented(plan, submittedAt: Double(i), requestedAt: Double(i),
                             presentedAt: Double(i) + 1, framesAhead: 0)
        }
        XCTAssertEqual(policy.presentationAdvance, 0)
        XCTAssertEqual(policy.originalPresentationAdvance, 0)
    }
    func testVisibilityFloorDoesNotHoldMissingPredecessorOrExceedRemainingWindow() {
        var policy = GameFramePresentationPolicy()
        var options = GameFramePresentationPolicy.Options()
        options.immediate = true; options.minimumCadenceGap = true
        let plan = policy.plan(sequence: 4, original: true, target: 1, expires: 1.022,
                               interval: 0.022, prequeued: true, options: options)
        policy.submitted(2)
        XCTAssertEqual(policy.minimumDuration(plan, at: 1, interval: 0.022), 0)
        policy.submitted(3)
        XCTAssertEqual(policy.minimumDuration(plan, at: 1, interval: 0.022), 0.003)
        XCTAssertEqual(policy.minimumDuration(plan, at: 1.021, interval: 0.022), 0)
        XCTAssertEqual(policy.minimumDuration(plan, at: .nan, interval: 0.022), 0)
        XCTAssertEqual(policy.minimumDuration(plan, at: 1, interval: .nan), 0)
        options.immediate = false
        let synced = policy.plan(sequence: 4, original: true, target: 1, expires: 1.022,
                                 interval: 0.022, prequeued: true, options: options)
        XCTAssertEqual(policy.minimumDuration(synced, at: 1, interval: 0.022), 0)
    }
}
