import CoreVideo
import Metal

/// Uses the same dimensions and filter as Apple's interpolation proxies.
/// The renderer upsamples the returned proxy just like a generated midpoint.
@available(macOS 26.0, *)
public final class SourceFrameProxyScaler {
    private let scaler: NV12Scaler
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    public init(device: MTLDevice) throws {
        scaler = try NV12Scaler(device: device)
    }

    public func encode(source: CVPixelBuffer, into commands: MTLCommandBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard let size = AppleLowLatencyProxySize.best(forWidth: width, height: height),
              size.width != width || size.height != height else { return source }
        if pool == nil || poolWidth != size.width || poolHeight != size.height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: size.width, kCVPixelBufferHeightKey: size.height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true
            ]
            pool = nil
            let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess else {
                throw AppleDownsampledFrameInterpolator.InterpolationError.pixelBufferPool(status)
            }
            poolWidth = size.width
            poolHeight = size.height
        }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool!, limits, &output)
        guard status == kCVReturnSuccess, let output else {
            throw AppleDownsampledFrameInterpolator.InterpolationError.pixelBufferPool(status)
        }
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferYCbCrMatrixKey, kCVImageBufferCGColorSpaceKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            }
        }
        try scaler.encodeScale(source: source, destination: output, into: commands)
        commands.addCompletedHandler { _ in
            withExtendedLifetime((source, output)) {}
        }
        return output
    }
}
