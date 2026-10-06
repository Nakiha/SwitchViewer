import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import VideoToolbox

/// Resolutions that `VTLowLatencyFrameInterpolationConfiguration` actually runs on.
///
/// The documented limit is `maximumDimensionForSpatialScaleFactor:` together with
/// `maximumPixelCountForSpatialScaleFactor:` (1920 and 2073600 on M5). In practice
/// the processor only accepts the resolutions its models were trained for: 576p,
/// 720p and 1080p. Other in-range sizes that satisfy the documented limits still
/// fail at process time with `VTFrameProcessorProcessingError` (-19740).
public enum AppleLowLatencyProxySize {
    public static let supported: [(width: Int, height: Int)] = [
        (1920, 1080), (1280, 720), (1024, 576)
    ]

    /// Largest supported proxy that still fits inside the input frame.
    public static func best(forWidth width: Int, height: Int, maximumWidth: Int = 1920) -> (width: Int, height: Int)? {
        supported.first { $0.width <= width && $0.height <= height && $0.width <= maximumWidth }
    }

    public static func supports(width: Int, height: Int) -> Bool {
        best(forWidth: width, height: height) != nil
    }
}

/// Runs Apple's temporal interpolator on a downsampled proxy of the input frames.
/// The renderer scales the generated proxy to the display drawable directly, so
/// source frames keep their native resolution while generated midpoints are softer.
///
/// When the input already matches a resolution Apple accepts, the frames go to
/// VideoToolbox unchanged; otherwise a full-frame proxy is produced first. Proxy
/// scaling completes before VideoToolbox receives the request; keeping these
/// submissions separate avoids the crashing Metal command-buffer API path.
#if !targetEnvironment(simulator)
@available(macOS 26.0, iOS 26.0, *)
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
        public let usedSeparateProcessorSubmission: Bool
        public let usedProxyScaling: Bool
    }

    public enum InterpolationError: Error, LocalizedError, CustomStringConvertible {
        case invalidDimensions
        case unsupportedInputSize(Int, Int)
        case unsupportedConfiguration
        case unsupportedPixelFormat(OSType)
        case pixelBufferPool(OSStatus)
        case invalidPresentationTimestamps
        case frameCreation
        case parametersCreation
        case alreadyProcessing
        case processor(String)
        case metalUnavailable
        case metalProcessing(String)

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "输入尺寸与插帧器配置不一致，或不是 NV12 缓冲"
            case .unsupportedInputSize(let width, let height):
                return "Apple 低延迟插帧不支持 \(width)×\(height)：需要至少 1024×576 的 NV12 输入"
            case .unsupportedConfiguration:
                return "Apple VideoToolbox 无法创建插帧配置"
            case .unsupportedPixelFormat(let format):
                return "Apple VideoToolbox 不支持 NV12 输入：\(format)"
            case .pixelBufferPool(let status):
                return "创建 Apple 插帧像素缓冲池失败：\(status)"
            case .invalidPresentationTimestamps:
                return "Apple 代理插帧要求有效且递增、间隔小于 1 秒的媒体时间戳"
            case .frameCreation:
                return "创建 Apple 插帧帧对象失败"
            case .parametersCreation:
                return "创建 Apple 插帧参数失败"
            case .alreadyProcessing:
                return "Apple 代理插帧器已有正在处理的任务"
            case .processor(let message):
                return "Apple 低延迟插帧失败：\(message)"
            case .metalUnavailable:
                return "没有可用的 Metal GPU"
            case .metalProcessing(let message):
                return "Metal NV12 缩放失败：\(message)"
            }
        }

        /// `localizedDescription` 走的是 LocalizedError，不实现它日志里只会出现错误序号。
        public var errorDescription: String? { description }
    }

    /// 输入尺寸。代理档位不变时可以就地改写，见 `reconfigure`。
    private var width: Int
    private var height: Int
    private let proxyWidth: Int
    private let proxyHeight: Int
    private let maximumProxyWidth: Int
    public let multiplier: InterpolationMultiplier
    /// False when the input already matches a resolution Apple accepts, in which
    /// case the captured buffers are submitted to VideoToolbox unchanged.
    private var scalesProxy: Bool
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
        var outputs: [CVPixelBuffer] = []
        var destinations: [VTFrameProcessorFrame] = []
        var onFrame: ((CVPixelBuffer, Double, Double) -> Void)?
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

    public var proxySize: (width: Int, height: Int) { (proxyWidth, proxyHeight) }
    public var usesProxyScaling: Bool { scalesProxy }

    /// 输入尺寸变了、但代理档位没变时，就地改写而不是重建。
    ///
    /// 重建一个 `AppleDownsampledFrameInterpolator` 会重新构造缩放器并重新启动
    /// VideoToolbox 会话（本机实测 28–65ms），而游戏在 3024×1898 与 3024×1764 之间
    /// 来回切换时用的是同一个 1920×1080 代理，会话本身完全没变。
    ///
    /// 调用方与 `submit` 在同一个串行队列上，因此不需要等待在途任务结束：
    /// 已经在处理的任务持有自己的输入输出缓冲，不受尺寸改写影响。
    public func reconfigure(width: Int, height: Int) throws {
        guard let proxy = AppleLowLatencyProxySize.best(forWidth: width, height: height, maximumWidth: maximumProxyWidth) else {
            throw InterpolationError.unsupportedInputSize(width, height)
        }
        guard proxy.width == proxyWidth, proxy.height == proxyHeight else {
            // 代理档位变了就必须重建会话。
            throw InterpolationError.unsupportedConfiguration
        }
        processLock.lock()
        defer { processLock.unlock() }
        self.width = width
        self.height = height
        self.scalesProxy = proxy.width != width || proxy.height != height
        // 尺寸变了，旧代理帧的时间戳对应关系不再可靠。
        proxyCache.removeAll(keepingCapacity: true)
        lastCurrentPresentationTimeStamp = nil
    }

    public init(width: Int, height: Int,
                pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, maximumProxyWidth: Int = 1920, multiplier: InterpolationMultiplier = .two) throws {
        guard let proxy = AppleLowLatencyProxySize.best(forWidth: width, height: height, maximumWidth: maximumProxyWidth) else {
            throw InterpolationError.unsupportedInputSize(width, height)
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: proxy.width, frameHeight: proxy.height,
                numberOfInterpolatedFrames: multiplier.configurationLevel) else {
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
        self.proxyWidth = proxy.width
        self.proxyHeight = proxy.height
        self.maximumProxyWidth = maximumProxyWidth
        self.multiplier = multiplier
        self.scalesProxy = proxy.width != width || proxy.height != height
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
        if sessionStarted { FrameProcessorSessionCleanup.end([processor]) }
    }

    public func submit(previous: CVPixelBuffer, current: CVPixelBuffer,
                       previousPresentationTimeStamp: CMTime,
                       currentPresentationTimeStamp: CMTime,
                       completion: @escaping (Result?, Error?) -> Void) throws {
        try submitJob(previous: previous, current: current,
            previousPresentationTimeStamp: previousPresentationTimeStamp,
            currentPresentationTimeStamp: currentPresentationTimeStamp, onFrame: nil, completion: completion)
    }

    /// Outputs may arrive out of phase order. Consumers schedule by media time.
    /// Buffers are read-only until the entire processor request has completed.
    public func submitFrames(previous: CVPixelBuffer, current: CVPixelBuffer,
                             previousPresentationTimeStamp: CMTime, currentPresentationTimeStamp: CMTime,
                             onFrame: @escaping (CVPixelBuffer, Double, Double) -> Void,
                             completion: @escaping (Result?, Error?) -> Void) throws {
        try submitJob(previous: previous, current: current,
            previousPresentationTimeStamp: previousPresentationTimeStamp,
            currentPresentationTimeStamp: currentPresentationTimeStamp, onFrame: onFrame, completion: completion)
    }

    private func submitJob(previous: CVPixelBuffer, current: CVPixelBuffer,
                           previousPresentationTimeStamp: CMTime, currentPresentationTimeStamp: CMTime,
                           onFrame: ((CVPixelBuffer, Double, Double) -> Void)?,
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

            let sourceIntervalSeconds = CMTimeGetSeconds(
                CMTimeSubtract(currentPresentationTimeStamp, previousPresentationTimeStamp))
            guard isNumeric(previousPresentationTimeStamp),
                  isNumeric(currentPresentationTimeStamp),
                  CMTimeCompare(currentPresentationTimeStamp, previousPresentationTimeStamp) > 0,
                  sourceIntervalSeconds > 0, sourceIntervalSeconds < 1 else {
                throw InterpolationError.invalidPresentationTimestamps
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
            let previousProxy: ProxyResult
            let currentProxy: ProxyResult
            let proxyEncodeCPUMilliseconds: Double
            let proxyCommandBuffer: MTLCommandBuffer?

            if scalesProxy {
                let encodeStart = ProcessInfo.processInfo.systemUptime
                let commandBuffer = try scaler.makeCommandBuffer()
                previousProxy = try proxyPixelBuffer(
                    from: previous, presentationTimeStamp: previousPresentationTimeStamp,
                    into: commandBuffer)
                currentProxy = try proxyPixelBuffer(
                    from: current, presentationTimeStamp: currentPresentationTimeStamp,
                    into: commandBuffer)
                proxyEncodeCPUMilliseconds = (ProcessInfo.processInfo.systemUptime - encodeStart) * 1_000
                proxyCommandBuffer = commandBuffer
            } else {
                // The capture already matches a resolution Apple accepts; submit it as-is.
                previousProxy = ProxyResult(pixelBuffer: previous, wasCached: false,
                                            cacheOnCompletion: false,
                                            presentationTimeStamp: previousPresentationTimeStamp)
                currentProxy = ProxyResult(pixelBuffer: current, wasCached: false,
                                           cacheOnCompletion: false,
                                           presentationTimeStamp: currentPresentationTimeStamp)
                proxyEncodeCPUMilliseconds = 0
                proxyCommandBuffer = nil
            }

            guard let previousFrame = VTFrameProcessorFrame(
                    buffer: previousProxy.pixelBuffer, presentationTimeStamp: previousPresentationTimeStamp),
                  let currentFrame = VTFrameProcessorFrame(
                    buffer: currentProxy.pixelBuffer, presentationTimeStamp: currentPresentationTimeStamp) else {
                throw InterpolationError.frameCreation
            }
            let job: AppleInterpolationJob
            if onFrame == nil {
                let midpoint = CMTimeAdd(previousPresentationTimeStamp,
                    CMTimeMultiplyByFloat64(CMTimeSubtract(currentPresentationTimeStamp,
                                                           previousPresentationTimeStamp), multiplier: 0.5))
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

                job = AppleInterpolationJob(
                    id: jobID, startedUptime: startedUptime,
                    previousSource: previous, currentSource: current,
                    previousProxy: previousProxy, currentProxy: currentProxy,
                    output: proxyOutput, previousFrame: previousFrame, currentFrame: currentFrame,
                    destinationFrame: destination, parameters: parameters,
                    proxyEncodeCPUMilliseconds: proxyEncodeCPUMilliseconds,
                    completion: completion)

            } else {
                let phases = multiplier.phases
                let outputs = try phases.map { _ -> CVPixelBuffer in
                    var output: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, proxyOutputPool, &output)
                    guard status == kCVReturnSuccess, let output else { throw InterpolationError.pixelBufferPool(status) }
                    // Attach before processing; early outputs must never be mutated.
                    if onFrame != nil { CVBufferPropagateAttachments(current, output) }
                    return output
                }
                let destinations = try zip(phases, outputs).map { phase, output -> VTFrameProcessorFrame in
                    let stamp = CMTimeAdd(previousPresentationTimeStamp,
                        CMTimeMultiplyByFloat64(CMTimeSubtract(currentPresentationTimeStamp, previousPresentationTimeStamp), multiplier: phase))
                    guard let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: stamp) else {
                        throw InterpolationError.frameCreation
                    }
                    return destination
                }
                guard let parameters = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: currentFrame, previousFrame: previousFrame,
                    interpolationPhase: phases.map(Float.init), destinationFrames: destinations) else {
                    throw InterpolationError.parametersCreation
                }
                job = AppleInterpolationJob(
                    id: jobID, startedUptime: startedUptime,
                    previousSource: previous, currentSource: current,
                    previousProxy: previousProxy, currentProxy: currentProxy,
                    output: outputs.last!, previousFrame: previousFrame, currentFrame: currentFrame,
                    destinationFrame: destinations.last!, parameters: parameters,
                    proxyEncodeCPUMilliseconds: proxyEncodeCPUMilliseconds,
                    completion: completion)
                if onFrame != nil { job.outputs = outputs; job.destinations = destinations; job.onFrame = onFrame }

            }

            if let commandBuffer = proxyCommandBuffer {
                let commitTime = CACurrentMediaTime()
                commandBuffer.addCompletedHandler { [self, job] completedBuffer in
                    if let resizeError = completedBuffer.error {
                        self.finish(job, result: nil,
                                    error: InterpolationError.metalProcessing(
                                        "代理缩放 command buffer 失败：\(resizeError.localizedDescription)"))
                        return
                    }
                    self.cacheProxyIfNeeded(job.previousProxy)
                    self.cacheProxyIfNeeded(job.currentProxy)
                    self.runProcessor(job,
                                      commitTime: commitTime,
                                      commandBufferCompletedAt: CACurrentMediaTime(),
                                      gpuStart: completedBuffer.gpuStartTime,
                                      gpuEnd: completedBuffer.gpuEndTime)
                }
                commandBuffer.commit()
            } else {
                let submitTime = CACurrentMediaTime()
                runProcessor(job, commitTime: submitTime,
                             commandBufferCompletedAt: submitTime,
                             gpuStart: 0, gpuEnd: 0)
            }
        } catch {
            releaseJob(jobID)
            throw error
        }
    }

    private func runProcessor(_ job: AppleInterpolationJob,
                              commitTime: CFTimeInterval,
                              commandBufferCompletedAt: CFTimeInterval,
                              gpuStart: CFTimeInterval,
                              gpuEnd: CFTimeInterval) {
        if let onFrame = job.onFrame {
            Task { [self, job] in
                do {
                    var delivered: Set<Int> = []
                    for try await frame in processor.process(parameters: job.parameters) {
                        guard let index = job.destinations.firstIndex(where: {
                            CMTimeCompare($0.presentationTimeStamp, frame.timeStamp) == 0
                        }) else { throw InterpolationError.frameCreation }
                        guard delivered.insert(index).inserted else { throw InterpolationError.frameCreation }
                        onFrame(job.outputs[index], multiplier.phases[index],
                                (ProcessInfo.processInfo.systemUptime - job.startedUptime) * 1000)
                    }
                    guard delivered.count == job.outputs.count else { throw InterpolationError.frameCreation }
                    finishProcessor(job, commitTime: commitTime, commandBufferCompletedAt: commandBufferCompletedAt,
                                    gpuStart: gpuStart, gpuEnd: gpuEnd, error: nil)
                } catch {
                    finishProcessor(job, commitTime: commitTime, commandBufferCompletedAt: commandBufferCompletedAt,
                                    gpuStart: gpuStart, gpuEnd: gpuEnd, error: error)
                }
            }
            return
        }
        processor.process(parameters: job.parameters) { [self, job] _, error in
            finishProcessor(job, commitTime: commitTime, commandBufferCompletedAt: commandBufferCompletedAt,
                            gpuStart: gpuStart, gpuEnd: gpuEnd, error: error)
        }
    }

    private func finishProcessor(_ job: AppleInterpolationJob, commitTime: Double,
                                 commandBufferCompletedAt: Double, gpuStart: Double, gpuEnd: Double, error processorError: Error?) {
        if let processorError {
            self.finish(job, result: nil,
                        error: InterpolationError.processor(
                            "VideoToolbox 插帧失败：\(processorError.localizedDescription)"))
            return
        }

        if job.onFrame == nil { CVBufferPropagateAttachments(job.currentSource, job.output) }
        let callbackTime = ProcessInfo.processInfo.systemUptime
        let result = Result(
            pixelBuffer: job.output,
            processingMilliseconds: (callbackTime - job.startedUptime) * 1_000,
            proxyEncodeCPUMilliseconds: job.proxyEncodeCPUMilliseconds,
            commandBufferCommitToGPUStartMilliseconds: gpuStart > 0
                ? max(0, gpuStart - commitTime) * 1_000 : 0,
            commandBufferGPUExecutionMilliseconds: gpuStart > 0 && gpuEnd >= gpuStart
                ? (gpuEnd - gpuStart) * 1_000 : 0,
            commandBufferCommitToCompleteMilliseconds:
                max(0, commandBufferCompletedAt - commitTime) * 1_000,
            interpolationSubmitToReadyMilliseconds: (callbackTime - job.startedUptime) * 1_000,
            outputWidth: CVPixelBufferGetWidth(job.output),
            outputHeight: CVPixelBufferGetHeight(job.output),
            proxyCacheHits: (job.previousProxy.wasCached ? 1 : 0)
                + (job.currentProxy.wasCached ? 1 : 0),
            proxyCacheMisses: (job.previousProxy.wasCached ? 0 : 1)
                + (job.currentProxy.wasCached ? 0 : 1),
            usedSeparateProcessorSubmission: true,
            usedProxyScaling: scalesProxy)
        self.finish(job, result: result, error: nil)
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
#endif
