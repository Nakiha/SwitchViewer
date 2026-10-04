import CoreMedia
import XCTest
@testable import SwitchViewerInterpolation

final class CaptureVideoFormatTests: XCTestCase {
    func testFractionalCadencesHaveDistinctVisibleLabels() {
        let sixty = CaptureVideoFormat(width: 3840, height: 2160, fps: 60, subtype: 0x646D6231)
        let ntsc = CaptureVideoFormat(width: 3840, height: 2160, fps: 59.94, subtype: 0x646D6231)
        XCTAssertTrue(sixty.label.contains("60 帧"))
        XCTAssertTrue(ntsc.label.contains("59.94 帧"))
        XCTAssertNotEqual(sixty.label, ntsc.label)
        XCTAssertNotEqual(sixty.id, ntsc.id)
    }

    func testNativeEncodingsAreNotDeduplicatedOrMislabeled() {
        let yuy2 = CaptureVideoFormat(width: 3840, height: 2160, fps: 60, subtype: 0x79757673)
        let mjpeg = CaptureVideoFormat(width: 3840, height: 2160, fps: 60, subtype: 0x646D6231)
        XCTAssertNotEqual(yuy2.id, mjpeg.id)
        XCTAssertTrue(yuy2.label.contains("YUY2"))
        XCTAssertTrue(mjpeg.label.contains("MJPEG"))
        XCTAssertEqual(Set([yuy2, mjpeg, yuy2]).count, 2)
        let jpeg = CaptureVideoFormat(width: 3840, height: 2160, fps: 60, subtype: 0x6A706567)
        XCTAssertNotEqual(jpeg.label, mjpeg.label)
    }

    func testNTSCFrameDurationsUseExactVideoTimeBase() {
        let ntsc60 = CaptureVideoFormat(width: 1920, height: 1080, fps: 59.94, subtype: 0x34323076)
        let ntsc30 = CaptureVideoFormat(width: 1920, height: 1080, fps: 29.97, subtype: 0x34323076)
        XCTAssertEqual(CMTimeCompare(ntsc60.frameDuration, CMTime(value: 1001, timescale: 60000)), 0)
        XCTAssertEqual(CMTimeCompare(ntsc30.frameDuration, CMTime(value: 1001, timescale: 30000)), 0)
    }

    func testNativeNTSCOnlyRangeDoesNotAdvertiseIntegerSixty() {
        let duration = CMTime(value: 1001, timescale: 60000)
        let ntsc = CaptureVideoFormat(width: 3840, height: 2160, fps: 59.94, subtype: 0x646D6231)
        let sixty = CaptureVideoFormat(width: 3840, height: 2160, fps: 60, subtype: 0x646D6231)
        XCTAssertTrue(ntsc.fits(minimumDuration: duration, maximumDuration: duration))
        XCTAssertFalse(sixty.fits(minimumDuration: duration, maximumDuration: duration))
    }

    func testRangeEndpointsAndKnownPixelFormatLabels() {
        let minimum = CMTime(value: 1, timescale: 60)
        let maximum = CMTime(value: 1, timescale: 30)
        for fps in [60.0, 59.94, 50, 30] {
            let format = CaptureVideoFormat(width: 1920, height: 1080, fps: fps, subtype: 0x34323076)
            XCTAssertTrue(format.fits(minimumDuration: minimum, maximumDuration: maximum))
            XCTAssertEqual(format.encodingLabel, "NV12")
        }
        let lower = CaptureVideoFormat(width: 1920, height: 1080, fps: 25, subtype: 0x32767579)
        XCTAssertFalse(lower.fits(minimumDuration: minimum, maximumDuration: maximum))
        XCTAssertEqual(lower.encodingLabel, "UYVY")
    }
}
