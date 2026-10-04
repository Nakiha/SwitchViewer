import XCTest
import CoreVideo
import Darwin
@testable import SwitchViewerInterpolation

final class ContentFrameRateMonitorTests: XCTestCase {
    private func buffer() -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &result), kCVReturnSuccess)
        return result!
    }
    private func signature(_ frame: Int, repeatEvery: Int = 1, overlay: Bool = false) -> DisplayFrameSignature {
        let content = UInt8(20 + (frame / repeatEvery % 20) * 5)
        let samples = Array(repeating: content, count: 100)
            + Array(repeating: overlay ? UInt8(40 + (frame % 20) * 5) : content, count: 4)
        return DisplayFrameSignature(width: 128, height: 72,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, yCbCrMatrix: nil,
            cadenceLumaSamples: samples, displayLumaSamples: samples, displayChromaSamples: [128, 128])
    }
    func testNative60HzHasAResultWithoutARepeatedFramePattern() {
        let monitor = ContentFrameRateMonitor(), buffer = buffer()
        var fps: Double?
        for frame in 0..<36 {
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, Int32(20 + frame * 5),
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!, 128,
                CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let sampled = SwitchFrameCadenceDetector.makeDisplayFrameSignature(from: buffer)
            XCTAssertNotNil(sampled)
            fps = monitor.observe(buffer, signature: sampled, time: Double(frame) / 60,
                captureCadence: true, generation: 1)
        }
        XCTAssertEqual(fps!, 60, accuracy: 0.01)
    }
    func test30HzContentInside60HzCaptureWithFasterOverlay() {
        let monitor = ContentFrameRateMonitor(), buffer = buffer()
        var fps: Double?
        for frame in 0..<36 {
            fps = monitor.observe(buffer, signature: signature(frame, repeatEvery: 2, overlay: true),
                time: Double(frame) / 60, captureCadence: true, generation: 1)
        }
        XCTAssertEqual(fps!, 30, accuracy: 0.01)
    }
    func testStaticContentBecomesZeroAndResumedContentWarmsUp() {
        let monitor = ContentFrameRateMonitor(), buffer = buffer()
        for frame in 0..<24 {
            _ = monitor.observe(buffer, signature: signature(frame), time: Double(frame) / 60,
                captureCadence: false, generation: 1)
        }
        let staticFPS = monitor.observe(buffer, signature: signature(23), time: 1.5,
            captureCadence: false, generation: 1)
        XCTAssertEqual(staticFPS, 0)
        XCTAssertNil(monitor.observe(buffer, signature: signature(24), time: 1.6,
            captureCadence: false, generation: 1))
    }
    func testNewSourceAndInvalidSamplesNeverReuseOldRates() {
        let monitor = ContentFrameRateMonitor(), buffer = buffer()
        for frame in 0..<24 {
            _ = monitor.observe(buffer, signature: signature(frame), time: Double(frame) / 60,
                captureCadence: true, generation: 1)
        }
        XCTAssertNil(monitor.observe(buffer, signature: signature(24), time: 2,
            captureCadence: true, generation: 2))
        XCTAssertNil(monitor.observe(buffer, signature: signature(25), time: 2.01,
            captureCadence: true, generation: 1))
        XCTAssertNil(monitor.observe(buffer, signature: nil, time: 2.02,
            captureCadence: true, generation: 2))
        XCTAssertNil(monitor.observe(buffer, signature: signature(26), time: .nan,
            captureCadence: true, generation: 2))
    }
}
