import XCTest
@testable import SwitchViewerInterpolation

final class GameFrameSubmissionArbiterTests: XCTestCase {
    func testUnfinishedMidpointCannotExtendOriginalSlot() {
        let a = GameFrameSubmissionArbiter()
        XCTAssertEqual(a.originalWaitUntil(sequence: 10, pendingMidpoint: 9, nominal: 1, expires: 2, now: 0.99), 1)
        XCTAssertNil(a.originalWaitUntil(sequence: 10, pendingMidpoint: 9, nominal: 1, expires: 2, now: 1))
    }
    func testReadyAcquiringMidpointGetsBoundedOwnership() {
        var a = GameFrameSubmissionArbiter()
        a.registerMidpoint(9)
        XCTAssertEqual(a.originalWaitUntil(sequence: 10, pendingMidpoint: 9, nominal: 1, expires: 2, now: 1), 1.001)
        XCTAssertNil(a.originalWaitUntil(sequence: 10, pendingMidpoint: 9, nominal: 1, expires: 2, now: 1.001))
        a.resolveMidpoint(9)
        XCTAssertNil(a.originalWaitUntil(sequence: 10, pendingMidpoint: 9, nominal: 1, expires: 2, now: 1))
    }
    func testExpiryAndOtherPairsDoNotExtendWait() {
        var a = GameFrameSubmissionArbiter()
        a.registerMidpoint(9)
        XCTAssertEqual(a.originalWaitUntil(sequence: 10, pendingMidpoint: 9, nominal: 1, expires: 1.0002, now: 1), 1.0002)
        XCTAssertNil(a.originalWaitUntil(sequence: 10, pendingMidpoint: 11, nominal: 1, expires: 2, now: 0.9))
        a.reset()
        XCTAssertNil(a.originalWaitUntil(sequence: 10, pendingMidpoint: 9, nominal: 1, expires: 2, now: 1))
    }
}
