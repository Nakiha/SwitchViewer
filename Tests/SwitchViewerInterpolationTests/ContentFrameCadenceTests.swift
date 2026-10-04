import XCTest
import CoreVideo
@testable import SwitchViewerInterpolation

final class ContentFrameCadenceTests: XCTestCase {
    private func signature(_ value: UInt8, width: Int = 1920) -> DisplayFrameSignature {
        DisplayFrameSignature(width: width, height: 1080,
                              pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              yCbCrMatrix: nil,
                              cadenceLumaSamples: [value], displayLumaSamples: [value],
                              displayChromaSamples: [128, 128])
    }

    func testDuplicatesKeepTheDistinctFramesTimestampWithJitter() {
        let detector = ContentFrameCadenceDetector()
        var time = 0.0
        _ = detector.observe(signature: signature(20), time: time)
        for i in 1...12 {
            XCTAssertTrue(detector.observe(signature: signature(UInt8(19 + i)), time: time + 0.017).isDuplicate)
            let interval = i % 2 == 0 ? 0.032 : 0.035
            time += interval
            let result = detector.observe(signature: signature(UInt8(20 + i)), time: time)
            XCTAssertTrue(result.shouldInterpolate)
            XCTAssertEqual(result.updateInterval!, interval, accuracy: 0.00001)
            if i >= 4 { XCTAssertEqual(result.observedFPS!, 30, accuracy: 2) }
        }
    }

    func testNative60AndVariableRatesDoNotNeedRepeatedCadence() {
        let detector = ContentFrameCadenceDetector()
        var time = 0.0
        for i in 0..<24 {
            let result = detector.observe(signature: signature(UInt8(20 + i)), time: time)
            if i >= 4 { XCTAssertEqual(result.observedFPS!, 60, accuracy: 0.01) }
            if i > 0 { XCTAssertTrue(result.shouldInterpolate) }
            time += 1.0 / 60
        }
        for i in 24..<48 {
            time += i % 2 == 0 ? 0.023 : 0.037
            let result = detector.observe(signature: signature(UInt8(20 + i)), time: time)
            XCTAssertTrue(result.shouldInterpolate)
            XCTAssertNotNil(result.observedFPS)
        }
    }

    func testPauseSceneCutFormatChangeAndClockResetDoNotGetWarped() {
        let detector = ContentFrameCadenceDetector()
        XCTAssertFalse(detector.observe(signature: signature(20), time: 0).shouldInterpolate)
        XCTAssertTrue(detector.observe(signature: signature(21), time: 0.017).shouldInterpolate)
        XCTAssertFalse(detector.observe(signature: signature(22), time: 1).shouldInterpolate)
        XCTAssertTrue(detector.observe(signature: signature(23), time: 1.017).shouldInterpolate)
        XCTAssertFalse(detector.observe(signature: signature(240), time: 1.034).shouldInterpolate)
        XCTAssertFalse(detector.observe(signature: signature(241, width: 2560), time: 1.051).shouldInterpolate)
        XCTAssertFalse(detector.observe(signature: signature(242), time: 0.1).shouldInterpolate)
        detector.reset()
        XCTAssertFalse(detector.observe(signature: signature(25), time: 5).shouldInterpolate)
    }
}
