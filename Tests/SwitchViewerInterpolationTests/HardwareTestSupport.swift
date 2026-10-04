import Foundation
import VideoToolbox
import XCTest

enum HardwareTestSupport {
    @available(macOS 26.0, *)
    static func requireAppleInterpolation() throws {
        // The hosted VM advertises support but returns -19740 on processing.
        // Keep this opt-out explicit; never reinterpret a processing regression
        // on the developer's actual hardware as a passing or skipped test.
        if ProcessInfo.processInfo.environment["SWITCHVIEWER_TEST_APPLE_INTERPOLATION"] == "0" {
            throw XCTSkip("Apple frame processing explicitly disabled on this test host; verify on real hardware")
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            throw XCTSkip("Apple interpolation is unavailable on this machine")
        }
    }
}
