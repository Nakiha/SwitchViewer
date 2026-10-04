import CoreMedia
import CoreVideo
import XCTest
@testable import SwitchViewerInterpolation

final class FrameProcessorLifecycleTests: XCTestCase {
    func testReleaseDuringInFlightProxyProcessing() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires VideoToolbox frame processing") }
        try HardwareTestSupport.requireAppleInterpolation()
        // Reproduce switching interpolation off while VideoToolbox owns the final
        // reference through its completion block. Destruction runs on its queue.
        for iteration in 0..<10 {
            var interpolator: AppleDownsampledFrameInterpolator? = try AppleDownsampledFrameInterpolator(width: 1920, height: 1080)
            weak var released = interpolator
            let previous = try frame(value: 80)
            let current = try frame(value: 120)
            let completed = expectation(description: "completed \(iteration)")
            try interpolator!.submit(previous: previous, current: current,
                previousPresentationTimeStamp: CMTime(value: 1, timescale: 60),
                currentPresentationTimeStamp: CMTime(value: 2, timescale: 60)) { result, error in
                XCTAssertNil(error)
                XCTAssertNotNil(result)
                completed.fulfill()
            }
            interpolator = nil
            wait(for: [completed], timeout: 10)
            let destroyed = expectation(description: "destroyed \(iteration)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                XCTAssertNil(released)
                FrameProcessorSessionCleanup.queue.sync {}
                destroyed.fulfill()
            }
            wait(for: [destroyed], timeout: 10)
        }
    }

    private func frame(value: Int32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        let status = CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(pb, plane)!, plane == 0 ? value : 128,
                CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
