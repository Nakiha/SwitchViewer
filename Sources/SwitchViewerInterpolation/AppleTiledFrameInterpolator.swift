import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Runs Apple's low-latency interpolator over 1080p tiles of a larger NV12 frame.
/// This preserves the input pixel dimensions when the tiles are stitched back
/// together, at the cost of losing motion context across tile boundaries.
@available(macOS 26.0, *)
public final class AppleTiledFrameInterpolator {
    public struct Result {
        public let pixelBuffer: CVPixelBuffer
        public let processingMilliseconds: Double
        public let preparationMilliseconds: Double
        public let processorMilliseconds: Double
        public let stitchingMilliseconds: Double
        public let tileCount: Int
        public let concurrentSessionCount: Int
        public let tileTimings: [TileTiming]
    }

    /// Wall-clock timing around each asynchronous VideoToolbox request. This
    /// measures request-to-callback latency, not private GPU/model execution.
    public struct TileTiming {
        public let tileIndex: Int
        public let processorIndex: Int
        public let requestStartOffsetMilliseconds: Double
        public let processCallMilliseconds: Double
        public let callbackLatencyMilliseconds: Double
        public let completionOffsetMilliseconds: Double
    }

    public enum InterpolationError: Error, CustomStringConvertible {
        case invalidDimensions
        case unsupportedPixelFormat(OSType)
        case unsupportedConfiguration
        case unsupportedDestinationFormat
        case pixelBufferPool(OSStatus)
        case pixelBufferLock(OSStatus)
        case frameCreation
        case parametersCreation
        case processor(String)
        case timedOut

        public var description: String {
            switch self {
            case .invalidDimensions:
                return "输入必须是可由 1920×1080 NV12 分块整除的偶数尺寸"
            case .unsupportedPixelFormat(let format):
                return "Apple VideoToolbox 不支持分块输入像素格式：\(format)"
            case .unsupportedConfiguration:
                return "Apple VideoToolbox 无法创建 1920×1080 插帧配置"
            case .unsupportedDestinationFormat:
                return "Apple 插帧输出格式与分块输入格式不一致"
            case .pixelBufferPool(let status):
                return "创建分块像素缓冲池失败：\(status)"
            case .pixelBufferLock(let status):
                return "锁定分块像素缓冲失败：\(status)"
            case .frameCreation:
                return "创建 Apple 插帧帧对象失败"
            case .parametersCreation:
                return "创建 Apple 插帧参数失败"
            case .processor(let message):
                return "Apple VideoToolbox 分块插帧失败：\(message)"
            case .timedOut:
                return "Apple VideoToolbox 分块插帧超时"
            }
        }
    }

    private let width: Int
    private let height: Int
    private let columns: Int
    private let rows: Int
    private let tileWidth: Int
    private let tileHeight: Int
    private let pixelFormat: OSType
    private let configuration: VTLowLatencyFrameInterpolationConfiguration
    private let processors: [VTFrameProcessor]
    public let sessionStartMilliseconds: [Double]
    private let inputPool: CVPixelBufferPool
    private let tileOutputPool: CVPixelBufferPool
    private let outputPool: CVPixelBufferPool
    private let processLock = NSLock()

    /// Creates a processor for a frame covered by a grid of 1920×1080 tiles.
    /// Initialize it away from the render callback because VideoToolbox may
    /// load its model while the session starts.
    public init(width: Int = 3840, height: Int = 2160,
                pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                columns: Int = 2, rows: Int = 2,
                maxConcurrentSessions: Int = 4) throws {
        guard columns > 0, rows > 0, maxConcurrentSessions > 0,
              width.isMultiple(of: columns * 2), height.isMultiple(of: rows * 2),
              width / columns == 1920, height / rows == 1080 else {
            throw InterpolationError.invalidDimensions
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width / columns,
                frameHeight: height / rows,
                numberOfInterpolatedFrames: 1) else {
            throw InterpolationError.unsupportedConfiguration
        }
        guard configuration.supportedPixelFormats.contains(pixelFormat) else {
            throw InterpolationError.unsupportedPixelFormat(pixelFormat)
        }

        let outputPixelFormat = (configuration.destinationPixelBufferAttributes[
            kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
        guard outputPixelFormat == pixelFormat else {
            throw InterpolationError.unsupportedDestinationFormat
        }

        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.tileWidth = width / columns
        self.tileHeight = height / rows
        self.pixelFormat = pixelFormat
        self.configuration = configuration
        self.inputPool = try Self.makePool(attributes: configuration.sourcePixelBufferAttributes)
        self.tileOutputPool = try Self.makePool(attributes: configuration.destinationPixelBufferAttributes)

        var fullFrameAttributes = configuration.destinationPixelBufferAttributes
        fullFrameAttributes[kCVPixelBufferWidthKey as String] = width
        fullFrameAttributes[kCVPixelBufferHeightKey as String] = height
        self.outputPool = try Self.makePool(attributes: fullFrameAttributes)

        let sessionCount = min(columns * rows, maxConcurrentSessions)
        let parallelProcessors = (0..<sessionCount).map { _ in VTFrameProcessor() }
        var startedProcessors: [VTFrameProcessor] = []
        var sessionStartTimes: [Double] = []
        do {
            for processor in parallelProcessors {
                let sessionStart = ProcessInfo.processInfo.systemUptime
                try processor.startSession(configuration: configuration)
                sessionStartTimes.append((ProcessInfo.processInfo.systemUptime - sessionStart) * 1_000)
                startedProcessors.append(processor)
            }
            self.processors = parallelProcessors
            self.sessionStartMilliseconds = sessionStartTimes
        } catch {
            startedProcessors.forEach { $0.endSession() }
            let fallbackProcessor = VTFrameProcessor()
            do {
                let sessionStart = ProcessInfo.processInfo.systemUptime
                try fallbackProcessor.startSession(configuration: configuration)
                self.sessionStartMilliseconds = [(ProcessInfo.processInfo.systemUptime - sessionStart) * 1_000]
                self.processors = [fallbackProcessor]
            } catch {
                throw InterpolationError.processor("启动会话失败：\(error.localizedDescription)")
            }
        }
    }

    deinit {
        FrameProcessorSessionCleanup.end(processors)
    }

    /// Synthesizes one midpoint frame from two full-size NV12 frames.
    /// Calls are serialized because a VTFrameProcessor session handles one
    /// request at a time.
    public func interpolate(previous: CVPixelBuffer, current: CVPixelBuffer,
                            previousPresentationTimeStamp: CMTime,
                            currentPresentationTimeStamp: CMTime) throws -> Result {
        processLock.lock()
        defer { processLock.unlock() }

        guard CVPixelBufferGetWidth(previous) == width,
              CVPixelBufferGetHeight(previous) == height,
              CVPixelBufferGetWidth(current) == width,
              CVPixelBufferGetHeight(current) == height,
              CVPixelBufferGetPixelFormatType(previous) == pixelFormat,
              CVPixelBufferGetPixelFormatType(current) == pixelFormat else {
            throw InterpolationError.invalidDimensions
        }

        var outputBuffer: CVPixelBuffer?
        let outputStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool, &outputBuffer)
        guard outputStatus == kCVReturnSuccess, let outputBuffer else {
            throw InterpolationError.pixelBufferPool(outputStatus)
        }
        let interval = CMTimeSubtract(currentPresentationTimeStamp, previousPresentationTimeStamp)
        let midpoint = CMTimeAdd(previousPresentationTimeStamp,
                                 CMTimeMultiplyByFloat64(interval, multiplier: 0.5))
        let start = ProcessInfo.processInfo.systemUptime

        struct TileJob {
            let processor: VTFrameProcessor
            let processorIndex: Int
            let previous: VTFrameProcessorFrame
            let current: VTFrameProcessorFrame
            let destination: VTFrameProcessorFrame
            let output: CVPixelBuffer
            let x: Int
            let y: Int
            let parameters: VTLowLatencyFrameInterpolationParameters
        }

        var jobs: [TileJob] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = column * tileWidth
                let y = row * tileHeight
                let previousTile = try Self.makeTile(from: previous, x: x, y: y,
                                                     width: tileWidth, height: tileHeight,
                                                     pool: inputPool)
                let currentTile = try Self.makeTile(from: current, x: x, y: y,
                                                    width: tileWidth, height: tileHeight,
                                                    pool: inputPool)
                var tileOutput: CVPixelBuffer?
                let tileOutputStatus = CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault, tileOutputPool, &tileOutput)
                guard tileOutputStatus == kCVReturnSuccess, let tileOutput else {
                    throw InterpolationError.pixelBufferPool(tileOutputStatus)
                }
                guard let previousFrame = VTFrameProcessorFrame(
                    buffer: previousTile, presentationTimeStamp: previousPresentationTimeStamp),
                      let currentFrame = VTFrameProcessorFrame(
                        buffer: currentTile, presentationTimeStamp: currentPresentationTimeStamp),
                      let destination = VTFrameProcessorFrame(buffer: tileOutput,
                                                             presentationTimeStamp: midpoint) else {
                    throw InterpolationError.frameCreation
                }
                guard let parameters = VTLowLatencyFrameInterpolationParameters(
                    sourceFrame: currentFrame,
                    previousFrame: previousFrame,
                    interpolationPhase: [0.5],
                    destinationFrames: [destination]) else {
                    throw InterpolationError.parametersCreation
                }
                let processorIndex = jobs.count % processors.count
                jobs.append(TileJob(processor: processors[processorIndex],
                                    processorIndex: processorIndex,
                                    previous: previousFrame, current: currentFrame,
                                    destination: destination, output: tileOutput, x: x, y: y,
                                    parameters: parameters))
            }
        }

        let processingStart = ProcessInfo.processInfo.systemUptime
        let errorLock = NSLock()
        var processingErrors: [Int: Error] = [:]
        var tileTimings = Array<TileTiming?>(repeating: nil, count: jobs.count)
        // Each processor handles one request at a time. With fewer sessions,
        // that session drains its assigned tiles serially while sessions run
        // concurrently with one another.
        DispatchQueue.concurrentPerform(iterations: processors.count) { processorIndex in
            for index in stride(from: processorIndex, to: jobs.count, by: processors.count) {
                let job = jobs[index]
                let completionSemaphore = DispatchSemaphore(value: 0)
                var processorError: Error?
                var callbackTime: TimeInterval?
                let requestStart = ProcessInfo.processInfo.systemUptime
                job.processor.process(parameters: job.parameters) { _, error in
                    let completedAt = ProcessInfo.processInfo.systemUptime
                    errorLock.lock()
                    processorError = error
                    callbackTime = completedAt
                    errorLock.unlock()
                    completionSemaphore.signal()
                }
                let callReturnedAt = ProcessInfo.processInfo.systemUptime
                let completed = completionSemaphore.wait(timeout: .now() + 5) == .success
                errorLock.lock()
                let resultError = processorError
                let completedAt = callbackTime
                if let completedAt {
                    tileTimings[index] = TileTiming(
                        tileIndex: index,
                        processorIndex: job.processorIndex,
                        requestStartOffsetMilliseconds: (requestStart - processingStart) * 1_000,
                        processCallMilliseconds: (callReturnedAt - requestStart) * 1_000,
                        callbackLatencyMilliseconds: (completedAt - requestStart) * 1_000,
                        completionOffsetMilliseconds: (completedAt - processingStart) * 1_000)
                }
                if !completed || resultError != nil {
                    processingErrors[index] = completed
                        ? resultError!
                        : InterpolationError.timedOut
                }
                errorLock.unlock()
            }
        }
        if let firstError = processingErrors.sorted(by: { $0.key < $1.key }).first?.value {
            throw InterpolationError.processor(firstError.localizedDescription)
        }
        let stitchingStart = ProcessInfo.processInfo.systemUptime
        for job in jobs {
            try Self.copyRegion(job.output, to: outputBuffer,
                                sourceX: 0, sourceY: 0,
                                destinationX: job.x, destinationY: job.y,
                                width: tileWidth, height: tileHeight)
        }
        let end = ProcessInfo.processInfo.systemUptime
        CVBufferPropagateAttachments(current, outputBuffer)
        let milliseconds = 1_000.0
        return Result(pixelBuffer: outputBuffer,
                      processingMilliseconds: (end - start) * milliseconds,
                      preparationMilliseconds: (processingStart - start) * milliseconds,
                      processorMilliseconds: (stitchingStart - processingStart) * milliseconds,
                      stitchingMilliseconds: (end - stitchingStart) * milliseconds,
                      tileCount: columns * rows,
                      concurrentSessionCount: processors.count,
                      tileTimings: tileTimings.compactMap { $0 }.sorted { $0.tileIndex < $1.tileIndex })
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

    private static func makeTile(from source: CVPixelBuffer, x: Int, y: Int,
                                 width: Int, height: Int,
                                 pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
        guard status == kCVReturnSuccess, let destination else {
            throw InterpolationError.pixelBufferPool(status)
        }
        try copyRegion(source, to: destination,
                       sourceX: x, sourceY: y, destinationX: 0, destinationY: 0,
                       width: width, height: height)
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private static func copyRegion(_ source: CVPixelBuffer, to destination: CVPixelBuffer,
                                   sourceX: Int, sourceY: Int,
                                   destinationX: Int, destinationY: Int,
                                   width: Int, height: Int) throws {
        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else { throw InterpolationError.pixelBufferLock(sourceLock) }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let destinationLock = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else { throw InterpolationError.pixelBufferLock(destinationLock) }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard CVPixelBufferGetPlaneCount(source) == 2,
              CVPixelBufferGetPlaneCount(destination) == 2 else {
            throw InterpolationError.unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(source))
        }
        for plane in 0..<2 {
            guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                throw InterpolationError.pixelBufferLock(kCVReturnError)
            }
            let verticalScale = plane == 0 ? 1 : 2
            let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
            let rowBytes = width
            for row in 0..<(height / verticalScale) {
                let sourceOffset = ((sourceY / verticalScale) + row) * sourceStride + sourceX
                let destinationOffset = ((destinationY / verticalScale) + row) * destinationStride + destinationX
                memcpy(destinationBase.advanced(by: destinationOffset),
                       sourceBase.advanced(by: sourceOffset), rowBytes)
            }
        }
    }

}
