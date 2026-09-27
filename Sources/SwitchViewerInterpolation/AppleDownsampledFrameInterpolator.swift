import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

/// Runs Apple's temporal interpolator on a full-frame 1080p proxy.
/// The renderer scales the generated proxy to the display drawable directly;
/// the original capture frames remain at their native resolution.
@available(macOS 26.0, *)
public final class AppleDownsampledFrameInterpolator {
    public struct Result {
        public let pixelBuffer: CVPixelBuffer
        public let processingMilliseconds: Double
        public let resizeMilliseconds: Double
        public let processorMilliseconds: Double
        public let outputWidth: Int
        public let outputHeight: Int
        public let proxyCacheHits: Int
        public let proxyCacheMisses: Int
    }

    public enum InterpolationError: Error, CustomStringConvertible {
        case invalidDimensions
        case unsupportedConfiguration
        case unsupportedPixelFormat(OSType)
        case pixelBufferPool(OSStatus)
        case frameCreation
        case parametersCreation
        case processor(String)
        case timedOut
        case metalUnavailable
        case metalProcessing(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "输入必须是 3840×2160 NV12"
            case .unsupportedConfiguration:
                return "Apple VideoToolbox 无法创建 1920×1080 插帧配置"
            case .unsupportedPixelFormat(let format):
                return "Apple VideoToolbox 不支持 NV12 输入：\(format)"
            case .pixelBufferPool(let status):
                return "创建 Apple 插帧像素缓冲池失败：\(status)"
            case .frameCreation:
                return "创建 Apple 插帧帧对象失败"
            case .parametersCreation:
                return "创建 Apple 插帧参数失败"
            case .processor(let message):
                return "Apple 低延迟插帧失败：\(message)"
            case .timedOut:
                return "Apple 低延迟插帧超时"
            case .metalUnavailable:
                return "没有可用的 Metal GPU"
            case .metalProcessing(let message):
                return "Metal NV12 缩放失败：\(message)"
            }
        }
    }

    private let width: Int
    private let height: Int
    private let proxyWidth = 1920
    private let proxyHeight = 1080
    private let processor = VTFrameProcessor()
    private let proxyInputPool: CVPixelBufferPool
    private let proxyOutputPool: CVPixelBufferPool
    private let scaler: NV12Scaler
    private let processLock = NSLock()
    private struct CachedProxyFrame {
        let presentationTimeStamp: CMTime
        let pixelBuffer: CVPixelBuffer
    }
    private let proxyCacheCapacity = 4
    private var proxyCache: [CachedProxyFrame] = []
    private var lastCurrentPresentationTimeStamp: CMTime?
    private var sessionStarted = false

    public init(width: Int = 3840, height: Int = 2160,
                pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws {
        guard width == 3840, height == 2160,
              width.isMultiple(of: proxyWidth), height.isMultiple(of: proxyHeight) else {
            throw InterpolationError.invalidDimensions
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: proxyWidth, frameHeight: proxyHeight,
                numberOfInterpolatedFrames: 1) else {
            throw InterpolationError.unsupportedConfiguration
        }
        guard configuration.supportedPixelFormats.contains(pixelFormat) else {
            throw InterpolationError.unsupportedPixelFormat(pixelFormat)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw InterpolationError.metalUnavailable
        }
        self.width = width
        self.height = height
        do {
            self.scaler = try NV12Scaler(device: device)
        } catch {
            throw InterpolationError.metalProcessing(String(describing: error))
        }
        let inputAttributes = configuration.sourcePixelBufferAttributes
        self.proxyInputPool = try Self.makePool(attributes: inputAttributes)
        let proxyOutputAttributes = configuration.destinationPixelBufferAttributes
        self.proxyOutputPool = try Self.makePool(attributes: proxyOutputAttributes)

        do {
            try processor.startSession(configuration: configuration)
            sessionStarted = true
        } catch {
            throw InterpolationError.processor("启动会话失败：\(error.localizedDescription)")
        }
    }

    deinit {
        if sessionStarted { processor.endSession() }
    }

    public func interpolate(previous: CVPixelBuffer, current: CVPixelBuffer,
                            previousPresentationTimeStamp: CMTime,
                            currentPresentationTimeStamp: CMTime) throws -> Result {
        processLock.lock()
        defer { processLock.unlock() }
        guard CVPixelBufferGetWidth(previous) == width,
              CVPixelBufferGetHeight(previous) == height,
              CVPixelBufferGetWidth(current) == width,
              CVPixelBufferGetHeight(current) == height,
              CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current),
              CVPixelBufferGetPixelFormatType(current) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            throw InterpolationError.invalidDimensions
        }

        if let lastCurrentPresentationTimeStamp,
           isNumeric(currentPresentationTimeStamp),
           isNumeric(lastCurrentPresentationTimeStamp),
           CMTimeCompare(currentPresentationTimeStamp, lastCurrentPresentationTimeStamp) < 0 {
            proxyCache.removeAll(keepingCapacity: true)
        }
        lastCurrentPresentationTimeStamp = isNumeric(currentPresentationTimeStamp)
            ? currentPresentationTimeStamp : nil

        let start = ProcessInfo.processInfo.systemUptime
        let (proxyPrevious, previousWasCached) = try proxyPixelBuffer(
            from: previous, presentationTimeStamp: previousPresentationTimeStamp)
        let (proxyCurrent, currentWasCached) = try proxyPixelBuffer(
            from: current, presentationTimeStamp: currentPresentationTimeStamp)
        let proxyEnd = ProcessInfo.processInfo.systemUptime

        let midpoint = CMTimeAdd(previousPresentationTimeStamp,
            CMTimeMultiplyByFloat64(CMTimeSubtract(currentPresentationTimeStamp,
                                                   previousPresentationTimeStamp), multiplier: 0.5))
        guard let previousFrame = VTFrameProcessorFrame(
                buffer: proxyPrevious, presentationTimeStamp: previousPresentationTimeStamp),
              let currentFrame = VTFrameProcessorFrame(
                buffer: proxyCurrent, presentationTimeStamp: currentPresentationTimeStamp) else {
            throw InterpolationError.frameCreation
        }
        var proxyOutput: CVPixelBuffer?
        let outputStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, proxyOutputPool, &proxyOutput)
        guard outputStatus == kCVReturnSuccess, let proxyOutput else {
            throw InterpolationError.pixelBufferPool(outputStatus)
        }
        guard let destination = VTFrameProcessorFrame(buffer: proxyOutput,
                                                      presentationTimeStamp: midpoint),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: currentFrame, previousFrame: previousFrame,
                interpolationPhase: [0.5], destinationFrames: [destination]) else {
            throw InterpolationError.parametersCreation
        }

        let completionSemaphore = DispatchSemaphore(value: 0)
        let completionLock = NSLock()
        var processorError: Error?
        processor.process(parameters: parameters) { _, error in
            completionLock.lock()
            processorError = error
            completionLock.unlock()
            completionSemaphore.signal()
        }
        guard completionSemaphore.wait(timeout: .now() + 5) == .success else {
            throw InterpolationError.timedOut
        }
        completionLock.lock()
        let resultError = processorError
        completionLock.unlock()
        if let resultError {
            throw InterpolationError.processor(resultError.localizedDescription)
        }
        let processorEnd = ProcessInfo.processInfo.systemUptime

        CVBufferPropagateAttachments(current, proxyOutput)
        let end = ProcessInfo.processInfo.systemUptime
        return Result(pixelBuffer: proxyOutput,
                      processingMilliseconds: (end - start) * 1_000,
                      resizeMilliseconds: (proxyEnd - start) * 1_000,
                      processorMilliseconds: (processorEnd - proxyEnd) * 1_000,
                      outputWidth: CVPixelBufferGetWidth(proxyOutput),
                      outputHeight: CVPixelBufferGetHeight(proxyOutput),
                      proxyCacheHits: (previousWasCached ? 1 : 0) + (currentWasCached ? 1 : 0),
                      proxyCacheMisses: (previousWasCached ? 0 : 1) + (currentWasCached ? 0 : 1))
    }

    private func proxyPixelBuffer(from source: CVPixelBuffer,
                                  presentationTimeStamp: CMTime) throws -> (CVPixelBuffer, Bool) {
        if isNumeric(presentationTimeStamp),
           let cacheIndex = proxyCache.firstIndex(where: {
               CMTimeCompare($0.presentationTimeStamp, presentationTimeStamp) == 0
           }) {
            let cached = proxyCache.remove(at: cacheIndex)
            proxyCache.append(cached)
            return (cached.pixelBuffer, true)
        }

        let proxy = try makePixelBuffer(from: source, pool: proxyInputPool)
        guard isNumeric(presentationTimeStamp) else { return (proxy, false) }

        proxyCache.append(CachedProxyFrame(presentationTimeStamp: presentationTimeStamp,
                                           pixelBuffer: proxy))
        if proxyCache.count > proxyCacheCapacity {
            proxyCache.removeFirst(proxyCache.count - proxyCacheCapacity)
        }
        return (proxy, false)
    }

    private func isNumeric(_ time: CMTime) -> Bool {
        CMTimeGetSeconds(time).isFinite
    }

    private func makePixelBuffer(from source: CVPixelBuffer,
                                 pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw InterpolationError.pixelBufferPool(status)
        }
        try scaler.scale(source, into: destination)
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private static func makePool(attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                             attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw InterpolationError.pixelBufferPool(status)
        }
        return pool
    }
}

@available(macOS 26.0, *)
private final class NV12Scaler {
    enum ScalingError: Error {
        case library(String)
        case pipeline(String)
        case textureCache(OSStatus)
        case texture(OSStatus)
        case commandBuffer
        case commandEncoder
        case commandExecution(String)
        case invalidFormat
    }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw ScalingError.commandBuffer }
        self.commandQueue = queue
        let shader = #"""
        #include <metal_stdlib>
        using namespace metal;

        float cubicWeight(float distance) {
            float x = abs(distance);
            if (x < 1.0) return 1.5 * x * x * x - 2.5 * x * x + 1.0;
            if (x < 2.0) return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0;
            return 0.0;
        }

        kernel void resizePlane(texture2d<float, access::read> input [[texture(0)]],
                                texture2d<float, access::write> output [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
            uint outputWidth = output.get_width();
            uint outputHeight = output.get_height();
            if (gid.x >= outputWidth || gid.y >= outputHeight) return;

            uint inputWidth = input.get_width();
            uint inputHeight = input.get_height();
            if (inputWidth == outputWidth * 2 && inputHeight == outputHeight * 2) {
                uint2 origin = gid * 2;
                float4 value = input.read(origin)
                             + input.read(origin + uint2(1, 0))
                             + input.read(origin + uint2(0, 1))
                             + input.read(origin + uint2(1, 1));
                output.write(value * 0.25, gid);
                return;
            }

            float2 position = ((float2(gid) + 0.5) *
                               float2(inputWidth, inputHeight) /
                               float2(outputWidth, outputHeight)) - 0.5;
            int2 base = int2(floor(position));
            float2 fraction = fract(position);
            int2 maximum = int2(inputWidth - 1, inputHeight - 1);
            float4 value = float4(0.0);
            for (int y = -1; y <= 2; ++y) {
                float4 row = float4(0.0);
                for (int x = -1; x <= 2; ++x) {
                    int2 coordinate = clamp(base + int2(x, y), int2(0), maximum);
                    row += input.read(uint2(coordinate)) * cubicWeight(fraction.x - float(x));
                }
                value += row * cubicWeight(fraction.y - float(y));
            }
            output.write(clamp(value, 0.0, 1.0), gid);
        }
        """#
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            guard let function = library.makeFunction(name: "resizePlane") else {
                throw ScalingError.library("缺少 resizePlane Metal 函数")
            }
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw ScalingError.pipeline(error.localizedDescription)
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw ScalingError.textureCache(status) }
        self.textureCache = cache
    }

    func scale(_ source: CVPixelBuffer, into destination: CVPixelBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(source) == 2,
              CVPixelBufferGetPlaneCount(destination) == 2 else {
            throw ScalingError.invalidFormat
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { throw ScalingError.commandBuffer }
        var textures: [CVMetalTexture] = []
        for plane in 0..<2 {
            let format: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
            let sourceWidth = CVPixelBufferGetWidthOfPlane(source, plane)
            let sourceHeight = CVPixelBufferGetHeightOfPlane(source, plane)
            let destinationWidth = CVPixelBufferGetWidthOfPlane(destination, plane)
            let destinationHeight = CVPixelBufferGetHeightOfPlane(destination, plane)
            var sourceTexture: CVMetalTexture?
            var destinationTexture: CVMetalTexture?
            let sourceStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, source, nil, format,
                sourceWidth, sourceHeight, plane, &sourceTexture)
            let destinationStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, destination, nil, format,
                destinationWidth, destinationHeight, plane, &destinationTexture)
            guard sourceStatus == kCVReturnSuccess, let sourceTexture,
                  destinationStatus == kCVReturnSuccess, let destinationTexture,
                  let sourceMetalTexture = CVMetalTextureGetTexture(sourceTexture),
                  let destinationMetalTexture = CVMetalTextureGetTexture(destinationTexture) else {
                throw ScalingError.texture(sourceStatus != kCVReturnSuccess ? sourceStatus : destinationStatus)
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw ScalingError.commandEncoder
            }
            textures.append(sourceTexture)
            textures.append(destinationTexture)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceMetalTexture, index: 0)
            encoder.setTexture(destinationMetalTexture, index: 1)
            let group = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: destinationWidth, height: destinationHeight, depth: 1)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
        }
        withExtendedLifetime(textures) {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        if let error = commandBuffer.error {
            throw ScalingError.commandExecution(error.localizedDescription)
        }
    }
}
