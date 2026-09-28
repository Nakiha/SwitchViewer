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
        public let resizeEncodeCPUMilliseconds: Double
        public let resizeCommitToGPUStartMilliseconds: Double
        public let resizeGPUExecutionMilliseconds: Double
        public let resizeCommitToCompleteMilliseconds: Double
        public let processorMilliseconds: Double
        public let interpolationSubmitToReadyMilliseconds: Double
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
        let proxyPreviousResult = try proxyPixelBuffer(
            from: previous, presentationTimeStamp: previousPresentationTimeStamp)
        let proxyCurrentResult = try proxyPixelBuffer(
            from: current, presentationTimeStamp: currentPresentationTimeStamp)
        let proxyPrevious = proxyPreviousResult.pixelBuffer
        let proxyCurrent = proxyCurrentResult.pixelBuffer
        let proxyEnd = ProcessInfo.processInfo.systemUptime
        let resizeMetrics = proxyPreviousResult.metrics + proxyCurrentResult.metrics

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
                      resizeEncodeCPUMilliseconds: resizeMetrics.encodeCPUMilliseconds,
                      resizeCommitToGPUStartMilliseconds: resizeMetrics.commitToGPUStartMilliseconds,
                      resizeGPUExecutionMilliseconds: resizeMetrics.gpuExecutionMilliseconds,
                      resizeCommitToCompleteMilliseconds: resizeMetrics.commitToCompleteMilliseconds,
                      processorMilliseconds: (processorEnd - proxyEnd) * 1_000,
                      interpolationSubmitToReadyMilliseconds: (processorEnd - proxyEnd) * 1_000,
                      outputWidth: CVPixelBufferGetWidth(proxyOutput),
                      outputHeight: CVPixelBufferGetHeight(proxyOutput),
                      proxyCacheHits: (proxyPreviousResult.wasCached ? 1 : 0)
                        + (proxyCurrentResult.wasCached ? 1 : 0),
                      proxyCacheMisses: (proxyPreviousResult.wasCached ? 0 : 1)
                        + (proxyCurrentResult.wasCached ? 0 : 1))
    }

    private struct ProxyResult {
        let pixelBuffer: CVPixelBuffer
        let wasCached: Bool
        let metrics: NV12ResizeMetrics
    }

    private func proxyPixelBuffer(from source: CVPixelBuffer,
                                  presentationTimeStamp: CMTime) throws -> ProxyResult {
        if isNumeric(presentationTimeStamp),
           let cacheIndex = proxyCache.firstIndex(where: {
               CMTimeCompare($0.presentationTimeStamp, presentationTimeStamp) == 0
           }) {
            let cached = proxyCache.remove(at: cacheIndex)
            proxyCache.append(cached)
            return ProxyResult(pixelBuffer: cached.pixelBuffer, wasCached: true, metrics: .zero)
        }

        let (proxy, metrics) = try makePixelBuffer(from: source, pool: proxyInputPool)
        guard isNumeric(presentationTimeStamp) else {
            return ProxyResult(pixelBuffer: proxy, wasCached: false, metrics: metrics)
        }

        proxyCache.append(CachedProxyFrame(presentationTimeStamp: presentationTimeStamp,
                                           pixelBuffer: proxy))
        if proxyCache.count > proxyCacheCapacity {
            proxyCache.removeFirst(proxyCache.count - proxyCacheCapacity)
        }
        return ProxyResult(pixelBuffer: proxy, wasCached: false, metrics: metrics)
    }

    private func isNumeric(_ time: CMTime) -> Bool {
        CMTimeGetSeconds(time).isFinite
    }

    private func makePixelBuffer(from source: CVPixelBuffer,
                                 pool: CVPixelBufferPool) throws -> (CVPixelBuffer, NV12ResizeMetrics) {
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw InterpolationError.pixelBufferPool(status)
        }
        let metrics = try scaler.scaleSynchronously(source, into: destination)
        CVBufferPropagateAttachments(source, destination)
        return (destination, metrics)
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
