import XCTest
@testable import SwitchViewerInterpolation

final class UnsyncedCadenceControllerTests: XCTestCase {
    func testRecordedWuwaPresentationPatternTriggersBoundedCorrection() throws {
        struct Sample: Decodable { let sequence: UInt64; let time: Double }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/unsynced-clustered-presentations.json")
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url))
        var control = UnsyncedCadenceController()
        for sample in samples { control.record(sequence: sample.sequence, presentedAt: sample.time) }
        XCTAssertGreaterThan(control.delay, 0)
        XCTAssertLessThanOrEqual(control.delay, 0.004)
    }

    func testSustainedClustersEarnBoundedCorrectionAndNormalCadenceRecovers() {
        var control = UnsyncedCadenceController()
        for i in 1...40 {
            control.record(sequence: UInt64(i * 2 - 1), presentedAt: Double(i))
            control.record(sequence: UInt64(i * 2), presentedAt: Double(i) + 0.001)
        }
        XCTAssertEqual(control.delay, 0.004, accuracy: 1e-9)
        XCTAssertEqual(control.submissionDelay(interval: 0.022, nominal: 1, expires: 1.1), 0.004)
        XCTAssertEqual(control.submissionDelay(interval: 0.022, nominal: 1, expires: 1.002), 0.001, accuracy: 1e-9)
        for i in 41...110 {
            control.record(sequence: UInt64(i * 2 - 1), presentedAt: Double(i))
            control.record(sequence: UInt64(i * 2), presentedAt: Double(i) + 0.010)
        }
        XCTAssertEqual(control.delay, 0)
    }
    func testIsolatedClustersStallsAndSkippedMidpointsDoNotEarnCorrection() {
        var control = UnsyncedCadenceController()
        for i in 1...60 {
            control.record(sequence: UInt64(i * 2 - 1), presentedAt: Double(i))
            control.record(sequence: UInt64(i * 2), presentedAt: Double(i) + (i % 10 == 0 ? 0.001 : 0.011))
        }
        XCTAssertEqual(control.delay, 0)
        control.record(sequence: 121, presentedAt: 61)
        control.record(sequence: 122, presentedAt: 62) // stall
        control.record(sequence: 124, presentedAt: 62.001) // no intervening midpoint
        control.record(sequence: 123, presentedAt: 62.0005) // old callback
        XCTAssertEqual(control.delay, 0)
        control.reset()
        XCTAssertEqual(control.delay, 0)
    }
}
