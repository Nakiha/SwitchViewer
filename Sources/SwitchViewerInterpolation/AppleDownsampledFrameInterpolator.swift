import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import VideoToolbox

/// Runs Apple's temporal interpolator on a full-frame 1080p proxy.
/// The renderer scales the generated proxy to the display drawable directly;
/// the original capture frames remain at their native resolution.
@available(macOS 26.0, *)
public final class AppleDownsampledFrameInterpolator {
    public struct Result {
        public let pixelBuffer: CVPixelBuffer
        public let processingMilliseconds: Double
        public let proxyEncodeCPUMilliseconds: Double
        public let commandBufferCommitToGPUStartMilliseconds: Double
        public let commandBufferGPUExecutionMilliseconds: Double
        public let commandBufferCommitToCompleteMilliseconds: Double
        public let interpolationSubmitToReadyMilliseconds: Double
        public let outputWidth: Int
        public let outputHeight: Int
        public let proxyCacheHits: Int
        public let proxyCacheMisses: Int
        public let usedSplitFallback: Bool
    }

    public enum InterpolationError: Error, CustomStringConvertible {
        case invalidDimensions
        case unsupportedConfiguration
        case unsupportedPixelFormat(OSType)
        case pixelBufferPool(OSStatus)
        case frameCreation
        case parametersCreation
        case alreadyProcessing
        case processor(String)
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
            case .alreadyProcessing:
                return "Apple 4K 代理插帧器已有正在处理的任务"
            case .processor(let message):
                return "Apple 低延迟插帧失败：\(message)"
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
    private var activeJobID: UInt64?
    private var nextJobID: UInt64 = 0
    private var sessionStarted = false

    private final class ProxyResult {
        let pixelBuffer: CVPixelBuffer
        let wasCached: Bool
        let cacheOnCompletion: Bool
        let presentationTimeStamp: CMTime

        init(pixelBuffer: CVPixelBuffer, wasCached: Bool, cacheOnCompletion: Bool,
             presentationTimeStamp: CMTime) {
            self.pixelBuffer = pixelBuffer
            self.wasCached = wasCached
            self.cacheOnCompletion = cacheOnCompletion
            self.presentationTimeStamp = presentationTimeStamp
        }
    }

    private final class AppleInterpolationJob {
        let id: UInt64
        let startedUptime: TimeInterval
        let previousSource: CVPixelBuffer
        let currentSource: CVPixelBuffer
        let previousProxy: ProxyResult
        let currentProxy: ProxyResult
        let output: CVPixelBuffer
        let previousFrame: VTFrameProcessorFrame
        let currentFrame: VTFrameProcessorFrame
        let destinationFrame: VTFrameProcessorFrame
        let parameters: VTLowLatencyFrameInterpolationParameters
        let proxyEncodeCPUMilliseconds: Double
        let completion: (Result?, Error?) -> Void

        init(id: UInt64, startedUptime: TimeInterval,
             previousSource: CVPixelBuffer, currentSource: CVPixelBuffer,
             previousProxy: ProxyResult, currentProxy: ProxyResult,
             output: CVPixelBuffer, previousFrame: VTFrameProcessorFrame,
             currentFrame: VTFrameProcessorFrame, destinationFrame: VTFrameProcessorFrame,
             parameters: VTLowLatencyFrameInterpolationParameters,
             proxyEncodeCPUMilliseconds: Double,
             completion: @escaping (Result?, Error?) -> Void) {
            self.id = id
            self.startedUptime = startedUptime
            self.previousSource = previousSource
            self.currentSource = currentSource
            self.previousProxy = previousProxy
            self.currentProxy = currentProxy
            self.output = output
            self.previousFrame = previousFrame
            self.currentFrame = currentFrame
            self.destinationFrame = destinationFrame
            self.parameters = parameters
            self.proxyEncodeCPUMilliseconds = proxyEncodeCPUMilliseconds
            self.completion = completion
        }
    }

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

    public func submit(previous: CVPixelBuffer, current: CVPixelBuffer,
                       previousPresentationTimeStamp: CMTime,
                       currentPresentationTimeStamp: CMTime,
                       completion: @escaping (Result?, Error?) -> Void) throws {
        let jobID = try reserveJob()
        do {
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

            let startedUptime = ProcessInfo.processInfo.systemUptime
            let encodeStart = ProcessInfo.processInfo.systemUptime
            let commandBuffer = try scaler.makeCommandBuffer()
            let previousProxy = try proxyPixelBuffer(
                from: previous, presentationTimeStamp: previousPresentationTimeStamp,
                into: commandBuffer)
            let currentProxy = try proxyPixelBuffer(
                from: current, presentationTimeStamp: currentPresentationTimeStamp,
                into: commandBuffer)
            let proxyEncodeCPUMilliseconds = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1_000

            let midpoint = CMTimeAdd(previousPresentationTimeStamp,
                CMTimeMultiplyByFloat64(CMTimeSubtract(currentPresentationTimeStamp,
                                                       previousPresentationTimeStamp), multiplier: 0.5))
            guard let previousFrame = VTFrameProcessorFrame(
                    buffer: previousProxy.pixelBuffer, presentationTimeStamp: previousPresentationTimeStamp),
                  let currentFrame = VTFrameProcessorFrame(
                    buffer: currentProxy.pixelBuffer, presentationTimeStamp: currentPresentationTimeStamp) else {
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

            let job = AppleInterpolationJob(
                id: jobID, startedUptime: startedUptime,
                previousSource: previous, currentSource: current,
                previousProxy: previousProxy, currentProxy: currentProxy,
                output: proxyOutput, previousFrame: previousFrame, currentFrame: currentFrame,
                destinationFrame: destination, parameters: parameters,
                proxyEncodeCPUMilliseconds: proxyEncodeCPUMilliseconds,
                completion: completion)
            processor.process(with: commandBuffer, parameters: job.parameters)
            let commitTime = CACurrentMediaTime()
            commandBuffer.addCompletedHandler { [self, job] completedBuffer in
                let commandBufferError = completedBuffer.error
                if let commandBufferError {
                    self.runSplitFallback(for: job, combinedError: commandBufferError)
                    return
                }

                self.cacheProxyIfNeeded(job.previousProxy)
                self.cacheProxyIfNeeded(job.currentProxy)
                CVBufferPropagateAttachments(job.currentSource, job.output)
                let callbackTime = ProcessInfo.processInfo.systemUptime
                let gpuStart = completedBuffer.gpuStartTime
                let gpuEnd = completedBuffer.gpuEndTime
                let result = Result(
                    pixelBuffer: job.output,
                    processingMilliseconds: (callbackTime - job.startedUptime) * 1_000,
                    proxyEncodeCPUMilliseconds: proxyEncodeCPUMilliseconds,
                    commandBufferCommitToGPUStartMilliseconds: gpuStart > 0
                        ? max(0, gpuStart - commitTime) * 1_000 : 0,
                    commandBufferGPUExecutionMilliseconds: gpuStart > 0 && gpuEnd >= gpuStart
                        ? (gpuEnd - gpuStart) * 1_000 : 0,
                    commandBufferCommitToCompleteMilliseconds:
                        max(0, CACurrentMediaTime() - commitTime) * 1_000,
                    interpolationSubmitToReadyMilliseconds: (callbackTime - job.startedUptime) * 1_000,
                    outputWidth: CVPixelBufferGetWidth(job.output),
                    outputHeight: CVPixelBufferGetHeight(job.output),
                    proxyCacheHits: (job.previousProxy.wasCached ? 1 : 0)
                        + (job.currentProxy.wasCached ? 1 : 0),
                    proxyCacheMisses: (job.previousProxy.wasCached ? 0 : 1)
                        + (job.currentProxy.wasCached ? 0 : 1),
                    usedSplitFallback: false)
                self.finish(job, result: result, error: nil)
            }
            commandBuffer.commit()
        } catch {
            releaseJob(jobID)
            throw error
        }
    }

    private func reserveJob() throws -> UInt64 {
        processLock.lock()
        defer { processLock.unlock() }
        guard activeJobID == nil else { throw InterpolationError.alreadyProcessing }
        nextJobID &+= 1
        activeJobID = nextJobID
        return nextJobID
    }

    private func releaseJob(_ jobID: UInt64) {
        processLock.lock()
        if activeJobID == jobID { activeJobID = nil }
        processLock.unlock()
    }

    private func finish(_ job: AppleInterpolationJob, result: Result?, error: Error?) {
        releaseJob(job.id)
        job.completion(result, error)
    }

    private func runSplitFallback(for job: AppleInterpolationJob, combinedError: Error) {
        do {
            let encodingStart = ProcessInfo.processInfo.systemUptime
            let commandBuffer = try scaler.makeCommandBuffer()
            let previousProxy = try proxyPixelBuffer(
                from: job.previousSource,
                presentationTimeStamp: job.previousFrame.presentationTimeStamp,
                into: commandBuffer)
            let currentProxy = try proxyPixelBuffer(
                from: job.currentSource,
                presentationTimeStamp: job.currentFrame.presentationTimeStamp,
                into: commandBuffer)
            let fallbackEncodeMilliseconds = (ProcessInfo.processInfo.systemUptime - encodingStart) * 1_000
            let commitTime = CACurrentMediaTime()
            commandBuffer.addCompletedHandler { [self, job] resizeBuffer in
                guard let resizeError = resizeBuffer.error else {
                    self.cacheProxyIfNeeded(previousProxy)
                    self.cacheProxyIfNeeded(currentProxy)
                    do {
                        var output: CVPixelBuffer?
                        let status = CVPixelBufferPoolCreatePixelBuffer(
                            kCFAllocatorDefault, self.proxyOutputPool, &output)
                        guard status == kCVReturnSuccess, let output else {
                            throw InterpolationError.pixelBufferPool(status)
                        }
                        let midpoint = CMTimeAdd(job.previousFrame.presentationTimeStamp,
                            CMTimeMultiplyByFloat64(
                                CMTimeSubtract(job.currentFrame.presentationTimeStamp,
                                               job.previousFrame.presentationTimeStamp),
                                multiplier: 0.5))
                        guard let previousFrame = VTFrameProcessorFrame(
                                buffer: previousProxy.pixelBuffer,
                                presentationTimeStamp: job.previousFrame.presentationTimeStamp),
                              let currentFrame = VTFrameProcessorFrame(
                                buffer: currentProxy.pixelBuffer,
                                presentationTimeStamp: job.currentFrame.presentationTimeStamp),
                              let destination = VTFrameProcessorFrame(
                                buffer: output, presentationTimeStamp: midpoint),
                              let parameters = VTLowLatencyFrameInterpolationParameters(
                                sourceFrame: currentFrame, previousFrame: previousFrame,
                                interpolationPhase: [0.5], destinationFrames: [destination]) else {
                            throw InterpolationError.parametersCreation
                        }
                        let fallbackJob = AppleInterpolationJob(
                            id: job.id, startedUptime: job.startedUptime,
                            previousSource: job.previousSource, currentSource: job.currentSource,
                            previousProxy: previousProxy, currentProxy: currentProxy,
                            output: output, previousFrame: previousFrame, currentFrame: currentFrame,
                            destinationFrame: destination, parameters: parameters,
                            proxyEncodeCPUMilliseconds: job.proxyEncodeCPUMilliseconds
                                + fallbackEncodeMilliseconds,
                            completion: job.completion)
                        self.processor.process(parameters: parameters) { [self, fallbackJob] _, processorError in
                            guard let processorError else {
                                CVBufferPropagateAttachments(fallbackJob.currentSource, fallbackJob.output)
                                let callbackTime = ProcessInfo.processInfo.systemUptime
                                let gpuStart = resizeBuffer.gpuStartTime
                                let gpuEnd = resizeBuffer.gpuEndTime
                                let result = Result(
                                    pixelBuffer: fallbackJob.output,
                                    processingMilliseconds:
                                        (callbackTime - fallbackJob.startedUptime) * 1_000,
                                    proxyEncodeCPUMilliseconds:
                                        fallbackJob.proxyEncodeCPUMilliseconds,
                                    commandBufferCommitToGPUStartMilliseconds: gpuStart > 0
                                        ? max(0, gpuStart - commitTime) * 1_000 : 0,
                                    commandBufferGPUExecutionMilliseconds: gpuStart > 0
                                        && gpuEnd >= gpuStart ? (gpuEnd - gpuStart) * 1_000 : 0,
                                    commandBufferCommitToCompleteMilliseconds:
                                        max(0, CACurrentMediaTime() - commitTime) * 1_000,
                                    interpolationSubmitToReadyMilliseconds:
                                        (callbackTime - fallbackJob.startedUptime) * 1_000,
                                    outputWidth: CVPixelBufferGetWidth(fallbackJob.output),
                                    outputHeight: CVPixelBufferGetHeight(fallbackJob.output),
                                    proxyCacheHits: (previousProxy.wasCached ? 1 : 0)
                                        + (currentProxy.wasCached ? 1 : 0),
                                    proxyCacheMisses: (previousProxy.wasCached ? 0 : 1)
                                        + (currentProxy.wasCached ? 0 : 1),
                                    usedSplitFallback: true)
                                self.finish(fallbackJob, result: result, error: nil)
                                return
                            }
                            self.finish(fallbackJob, result: nil,
                                        error: InterpolationError.processor(
                                            "合并 command buffer 失败：\(combinedError.localizedDescription)；"
                                                + "异步回退失败：\(processorError.localizedDescription)"))
                        }
                    } catch {
                        self.finish(job, result: nil,
                                    error: InterpolationError.processor(
                                        "合并 command buffer 失败：\(combinedError.localizedDescription)；"
                                            + "异步回退失败：\(String(describing: error))"))
                    }
                    return
                }
                self.finish(job, result: nil,
                            error: InterpolationError.processor(
                                "合并 command buffer 失败：\(combinedError.localizedDescription)；"
                                    + "回退缩放失败：\(resizeError.localizedDescription)"))
            }
            commandBuffer.commit()
        } catch {
            finish(job, result: nil,
                   error: InterpolationError.processor(
                    "合并 command buffer 失败：\(combinedError.localizedDescription)；"
                        + "异步回退提交失败：\(String(describing: error))"))
        }
    }

    private func proxyPixelBuffer(from source: CVPixelBuffer,
                                  presentationTimeStamp: CMTime,
                                  into commandBuffer: MTLCommandBuffer) throws -> ProxyResult {
        if isNumeric(presentationTimeStamp),
           let cacheIndex = proxyCache.firstIndex(where: {
               CMTimeCompare($0.presentationTimeStamp, presentationTimeStamp) == 0
           }) {
            let cached = proxyCache.remove(at: cacheIndex)
            proxyCache.append(cached)
            return ProxyResult(pixelBuffer: cached.pixelBuffer, wasCached: true,
                               cacheOnCompletion: false, presentationTimeStamp: presentationTimeStamp)
        }

        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, proxyInputPool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw InterpolationError.pixelBufferPool(status)
        }
        try scaler.encodeScale(source: source, destination: destination, into: commandBuffer)
        CVBufferPropagateAttachments(source, destination)
        return ProxyResult(pixelBuffer: destination, wasCached: false,
                           cacheOnCompletion: isNumeric(presentationTimeStamp),
                           presentationTimeStamp: presentationTimeStamp)
    }

    private func cacheProxyIfNeeded(_ proxy: ProxyResult) {
        guard proxy.cacheOnCompletion, isNumeric(proxy.presentationTimeStamp) else { return }
        proxyCache.removeAll {
            CMTimeCompare($0.presentationTimeStamp, proxy.presentationTimeStamp) == 0
        }
        proxyCache.append(CachedProxyFrame(presentationTimeStamp: proxy.presentationTimeStamp,
                                           pixelBuffer: proxy.pixelBuffer))
        if proxyCache.count > proxyCacheCapacity {
            proxyCache.removeFirst(proxyCache.count - proxyCacheCapacity)
        }
    }

    private func isNumeric(_ time: CMTime) -> Bool {
        CMTimeGetSeconds(time).isFinite
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
