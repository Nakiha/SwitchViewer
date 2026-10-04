import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

struct PresentationFrame {
    let pixelBuffer: CVPixelBuffer
    let displaySignature: DisplayFrameSignature?
    let isInterpolated: Bool
    let minimumPresentationDuration: TimeInterval?
    let presentationTimestampHostTime: CFTimeInterval?
    let targetPresentationHostTime: CFTimeInterval?
    let sourceID: UInt64?
    let sourceContentRootID: UInt64?
    /// 该帧应该按什么宽高比显示。插值帧是源帧的非等比缩放代理（例如
    /// 3024×1898 → 1920×1080），如果按它自己的宽高比做等比适配，插值帧和源帧
    /// 的显示比例就不一致，看起来会来回闪。插值帧必须沿用其源帧的宽高比。
    /// nil = 用缓冲自身的宽高比。
    let referenceAspect: Float?
    let timing: PresentationFrameTiming

    init(pixelBuffer: CVPixelBuffer, displaySignature: DisplayFrameSignature? = nil,
         isInterpolated: Bool,
         minimumPresentationDuration: TimeInterval?,
         presentationTimestampHostTime: CFTimeInterval?,
         targetPresentationHostTime: CFTimeInterval? = nil,
         sourceID: UInt64? = nil,
         sourceContentRootID: UInt64? = nil,
         referenceAspect: Float? = nil,
         timing: PresentationFrameTiming) {
        self.pixelBuffer = pixelBuffer
        self.displaySignature = displaySignature
        self.isInterpolated = isInterpolated
        self.minimumPresentationDuration = minimumPresentationDuration
        self.presentationTimestampHostTime = presentationTimestampHostTime
        self.targetPresentationHostTime = targetPresentationHostTime
        self.sourceID = sourceID
        self.sourceContentRootID = sourceContentRootID
        self.referenceAspect = referenceAspect
        self.timing = timing
    }
}

protocol FrameInterpolationEngine: AnyObject {
    func submit(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime,
                displaySignature: DisplayFrameSignature?,
                contentTimed: Bool,
                completion: @escaping FrameInterpolationCompletion)
    func setMode(_ mode: FrameInterpolationMode)
    func reset()
}

enum AppleLowLatencyFrameSupport {
    static let supportedPixelFormats: Set<OSType> = {
        guard #available(macOS 26.0, *),
              VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: 1920, frameHeight: 1080, numberOfInterpolatedFrames: 1) else {
            return []
        }
        return Set(configuration.supportedPixelFormats)
    }()
}

func canUseAppleLowLatencyFrame(width: Int, height: Int, pixelFormat: OSType) -> Bool {
    width == 1920 && height == 1080
        && AppleLowLatencyFrameSupport.supportedPixelFormats.contains(pixelFormat)
}

func canUseAppleProxy(width: Int, height: Int, pixelFormat: OSType) -> Bool {
    pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        && AppleLowLatencyFrameSupport.supportedPixelFormats.contains(pixelFormat)
        && AppleLowLatencyProxySize.supports(width: width, height: height)
}

