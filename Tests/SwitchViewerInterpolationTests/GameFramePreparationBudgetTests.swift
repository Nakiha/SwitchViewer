import XCTest
@testable import SwitchViewerInterpolation

final class GameFramePreparationBudgetTests: XCTestCase {
    func testAcquiredFrameDoesNotReserveAlreadyFinishedWork() {
        var budget = GameFramePreparationBudget()
        XCTAssertEqual(budget.reserve(lead: 0.013, acquired: false), 0.00375, accuracy: 1e-9)
        for _ in 0..<12 {
            budget.recordAcquisition(0.007)
            budget.recordEncoding(0.0002)
        }
        XCTAssertEqual(budget.reserve(lead: 0.013, acquired: false), 0.0075, accuracy: 1e-9)
        XCTAssertEqual(budget.reserve(lead: 0.013, acquired: true), 0.0005, accuracy: 1e-9)
        XCTAssertEqual(budget.reserve(lead: 0.004, acquired: false), 0.004)
    }
    func testStallAndInvalidSamplesCannotPoisonBudgetAndPressureCanRecover() {
        var budget = GameFramePreparationBudget()
        for _ in 0..<45 { budget.recordAcquisition(0.012) }
        for _ in 0..<45 { budget.recordAcquisition(0.001) }
        for value in [Double.nan, Double.infinity, -1, 1] {
            budget.recordAcquisition(value); budget.recordEncoding(value)
        }
        XCTAssertEqual(budget.reserve(lead: 0.013, acquired: false), 0.00175, accuracy: 1e-9)
        XCTAssertEqual(budget.reserve(lead: .nan, acquired: false), 0)
    }
}
