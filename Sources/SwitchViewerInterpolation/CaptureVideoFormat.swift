import CoreMedia
import Foundation

/// A capture mode's identity includes its native encoding and exact frame cadence.
public struct CaptureVideoFormat: Identifiable, Equatable, Hashable {
    public let width: Int32
    public let height: Int32
    public let fps: Double
    public let subtype: FourCharCode

    public init(width: Int32, height: Int32, fps: Double, subtype: FourCharCode) {
        self.width = width
        self.height = height
        self.fps = fps
        self.subtype = subtype
    }

    public var id: String { "\(width)x\(height)@\(fps):\(subtype)" }

    public var frameRateLabel: String {
        abs(fps - fps.rounded()) < 0.001
            ? String(format: "%.0f", fps) : String(format: "%.2f", fps)
    }

    public var encodingLabel: String {
        switch subtype {
        case 0x34323076: return "NV12"       // 420v
        case 0x34323066: return "NV12 全范围" // 420f
        case 0x79757673: return "YUY2"       // yuvs
        case 0x32767579: return "UYVY"       // 2vuy
        case 0x6A706567: return "JPEG"
        case 0x646D6231: return "MJPEG"
        default:
            let bytes = [UInt8((subtype >> 24) & 255), UInt8((subtype >> 16) & 255),
                         UInt8((subtype >> 8) & 255), UInt8(subtype & 255)]
            return String(bytes: bytes, encoding: .ascii) ?? String(format: "%08X", subtype)
        }
    }

    public var label: String { "\(width)×\(height) · \(frameRateLabel) 帧 · \(encodingLabel)" }

    public var frameDuration: CMTime {
        switch fps {
        case 59.94: return CMTime(value: 1001, timescale: 60_000)
        case 29.97: return CMTime(value: 1001, timescale: 30_000)
        default: return CMTime(seconds: 1 / fps, preferredTimescale: 600_000)
        }
    }

    public func fits(minimumDuration: CMTime, maximumDuration: CMTime) -> Bool {
        CMTimeCompare(frameDuration, minimumDuration) >= 0 &&
        CMTimeCompare(frameDuration, maximumDuration) <= 0
    }
}
