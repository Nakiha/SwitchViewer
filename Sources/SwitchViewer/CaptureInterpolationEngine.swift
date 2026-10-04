import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

@available(macOS 26.0, *)
final class AdaptiveFrameInterpolator: FrameInterpolationEngine {
    private struct Submission {
        let buffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let displaySignature: DisplayFrameSignature?
        let contentTimed: Bool
        let completion: FrameInterpolationCompletion
        let submittedAtUptime: TimeInterval
    }

    private struct CapturedFrame {
        let buffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
    }

    private struct Input {
        let buffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let completion: FrameInterpolationCompletion
        let previousBuffer: CVPixelBuffer?
        let previousPresentationTimeStamp: CMTime?
        let shouldInterpolate: Bool
        let repeatedGameFrame: Bool
        let cadenceMilliseconds: Double
        let submittedAtUptime: TimeInterval
        let detectedGameFPS: Double?
    }

    private struct TimingSample {
        let backend: String
        let detectedGameFPS: Double?
        let gameFrameIntervalMilliseconds: Double
        let cadenceMilliseconds: Double
        let queueMilliseconds: Double
        let preprocessingMilliseconds: Double
        let commandBufferQueueWaitMilliseconds: Double
        let commandBufferGPUExecutionMilliseconds: Double
        let commandBufferCommitToCompleteMilliseconds: Double
        let interpolationSubmitToReadyMilliseconds: Double
        let providerMilliseconds: Double
        let appleOrCombinedProcessingMilliseconds: Double
        let captureToReadyMilliseconds: Double
        let proxyCacheHits: Int
        let proxyCacheMisses: Int
        let usedSeparateProcessorSubmission: Bool
    }

    private let queue = DispatchQueue(label: "switchviewer.frame-interpolation")
    private let submissionLock = NSLock()
    private var processor = VTFrameProcessor()
    private let cadenceDetector = SwitchFrameCadenceDetector()
    private let contentCadenceDetector = ContentFrameCadenceDetector()
    private var lastContentFrame: CapturedFrame?
    private var lastContentRateReport = 0.0
    private let onRepeatedGameFrameSkipped: () -> Void
    private let onCadenceChanged: (Double?) -> Void
    private let onQueuedFramesDropped: (Int) -> Void
    private let onBackendChanged: (String) -> Void
    private let onTimingReport: (String) -> Void
    private var pending: [Input] = []
    // Keep capture callbacks from building an unbounded dispatch backlog when
    // full-resolution analysis takes longer than the capture cadence.
    private var latestSubmission: Submission?
    private var isSubmissionDrainScheduled = false
    private var recentCaptureFrames: [CapturedFrame] = []
    private var timingSamples: [TimingSample] = []
    private var lastTimingReportUptime = ProcessInfo.processInfo.systemUptime
    private var isProcessing = false
    private var resetAfterCurrent = false
    private var processingDisabledError: String?
    private var sessionSetupError: String?
    private var sessionStarted = false
    private var width = 0
    private var height = 0
    private var pixelFormat: OSType = 0
    private var outputPool: CVPixelBufferPool?
    private var frameConfig: VTLowLatencyFrameInterpolationConfiguration?
    private var appleProxyInterpolator: AppleDownsampledFrameInterpolator?
    private var activeBackend: String?
    private var mode: FrameInterpolationMode = .appleProxy

    init(onRepeatedGameFrameSkipped: @escaping () -> Void = {},
         onCadenceChanged: @escaping (Double?) -> Void = { _ in },
         onQueuedFramesDropped: @escaping (Int) -> Void = { _ in },
         onBackendChanged: @escaping (String) -> Void = { _ in },
         onTimingReport: @escaping (String) -> Void = { _ in }) {
        self.onRepeatedGameFrameSkipped = onRepeatedGameFrameSkipped
        self.onCadenceChanged = onCadenceChanged
        self.onQueuedFramesDropped = onQueuedFramesDropped
        self.onBackendChanged = onBackendChanged
        self.onTimingReport = onTimingReport
    }

    func submit(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime,
                displaySignature: DisplayFrameSignature?,
                contentTimed: Bool,
                completion: @escaping FrameInterpolationCompletion) {
        let submission = Submission(buffer: pixelBuffer,
                                    presentationTimeStamp: presentationTimeStamp,
                                    displaySignature: displaySignature,
                                    contentTimed: contentTimed,
                                    completion: completion,
                                    submittedAtUptime: ProcessInfo.processInfo.systemUptime)
        submissionLock.lock()
        let replacedSubmission = latestSubmission
        latestSubmission = submission
        let shouldScheduleDrain = !isSubmissionDrainScheduled
        if shouldScheduleDrain { isSubmissionDrainScheduled = true }
        submissionLock.unlock()

        if replacedSubmission != nil { onQueuedFramesDropped(1) }
        if shouldScheduleDrain {
            queue.async { self.drainLatestSubmission() }
        }
    }

    private func drainLatestSubmission() {
        submissionLock.lock()
        guard let submission = latestSubmission else {
            isSubmissionDrainScheduled = false
            submissionLock.unlock()
            return
        }
        latestSubmission = nil
        submissionLock.unlock()

        if submission.contentTimed {
            drainContentSubmission(submission)
            scheduleNextSubmission()
            return
        }
        let cadenceStart = ProcessInfo.processInfo.systemUptime
        let seconds = CMTimeGetSeconds(submission.presentationTimeStamp)
        let cadence: SwitchFrameCadenceDetector.Result?
        if seconds.isFinite {
            cadence = cadenceDetector.observe(submission.buffer, presentationTime: seconds,
                                               signature: submission.displaySignature)
        } else {
            cadenceDetector.reset()
            cadence = nil
        }
        onCadenceChanged(cadence?.gameFPS)
        let cadenceMilliseconds = (ProcessInfo.processInfo.systemUptime - cadenceStart) * 1_000

        let previousCapturedFrame = recentCaptureFrames.last
        let previousFrame: CapturedFrame?
        if let cadence, cadence.gameFPS != nil, !cadence.repeatedGameFrame,
           let distance = cadence.intervalsSincePreviousGameUpdate,
           distance > 0, recentCaptureFrames.count >= distance {
            previousFrame = recentCaptureFrames[recentCaptureFrames.count - distance]
        } else {
            previousFrame = previousCapturedFrame
        }
        recentCaptureFrames.append(CapturedFrame(buffer: submission.buffer,
                                                 presentationTimeStamp: submission.presentationTimeStamp))
        if recentCaptureFrames.count > 3 {
            recentCaptureFrames.removeFirst(recentCaptureFrames.count - 3)
        }
        if pending.count >= 2 {
            let dropped = pending.count
            pending.removeAll(keepingCapacity: true)
            onQueuedFramesDropped(dropped)
        }
        pending.append(Input(buffer: submission.buffer,
                             presentationTimeStamp: submission.presentationTimeStamp,
                             completion: submission.completion,
                             previousBuffer: previousFrame?.buffer,
                             previousPresentationTimeStamp: previousFrame?.presentationTimeStamp,
                             shouldInterpolate: cadence?.shouldInterpolate ?? false,
                             repeatedGameFrame: cadence?.gameFPS != nil && cadence?.repeatedGameFrame == true,
                             cadenceMilliseconds: cadenceMilliseconds,
                             submittedAtUptime: submission.submittedAtUptime,
                             detectedGameFPS: cadence?.gameFPS))
        processNext()

        scheduleNextSubmission()
    }

    private func scheduleNextSubmission() {
        submissionLock.lock()
        let hasMoreSubmissions = latestSubmission != nil
        if !hasMoreSubmissions { isSubmissionDrainScheduled = false }
        submissionLock.unlock()
        if hasMoreSubmissions {
            queue.async { self.drainLatestSubmission() }
        }
    }

    private func drainContentSubmission(_ submission: Submission) {
        let start = ProcessInfo.processInfo.systemUptime
        let result = contentCadenceDetector.observe(signature: submission.displaySignature,
                                                    time: CMTimeGetSeconds(submission.presentationTimeStamp))
        if result.isDuplicate {
            onRepeatedGameFrameSkipped()
            submission.completion(nil, nil, nil)
            return
        }
        let previous = lastContentFrame
        lastContentFrame = CapturedFrame(buffer: submission.buffer,
                                        presentationTimeStamp: submission.presentationTimeStamp)
        if start - lastContentRateReport >= 1 {
            lastContentRateReport = start
            onCadenceChanged(result.observedFPS)
        }
        if pending.count >= 2 {
            onQueuedFramesDropped(pending.count)
            pending.removeAll(keepingCapacity: true)
        }
        pending.append(Input(buffer: submission.buffer,
                             presentationTimeStamp: submission.presentationTimeStamp,
                             completion: submission.completion,
                             previousBuffer: previous?.buffer,
                             previousPresentationTimeStamp: previous?.presentationTimeStamp,
                             shouldInterpolate: result.shouldInterpolate,
                             repeatedGameFrame: false,
                             cadenceMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                             submittedAtUptime: submission.submittedAtUptime,
                             detectedGameFPS: result.observedFPS))
        processNext()
    }

    func reset() {
        queue.async {
            self.submissionLock.lock()
            self.latestSubmission = nil
            self.submissionLock.unlock()
            self.pending.removeAll(keepingCapacity: true)
            self.recentCaptureFrames.removeAll(keepingCapacity: true)
            self.timingSamples.removeAll(keepingCapacity: true)
            self.lastTimingReportUptime = ProcessInfo.processInfo.systemUptime
            self.cadenceDetector.reset()
            self.contentCadenceDetector.reset()
            self.lastContentFrame = nil
            self.lastContentRateReport = 0
            self.onCadenceChanged(nil)
            self.appleProxyInterpolator = nil
            if self.isProcessing {
                self.resetAfterCurrent = true
            } else {
                self.endVideoToolboxSession()
            }
        }
    }

    func setMode(_ mode: FrameInterpolationMode) {
        queue.async {
            guard self.mode != mode else { return }
            self.mode = mode
            self.submissionLock.lock()
            self.latestSubmission = nil
            self.submissionLock.unlock()
            for input in self.pending {
                input.completion(nil, nil, nil)
            }
            self.pending.removeAll(keepingCapacity: true)
            self.recentCaptureFrames.removeAll(keepingCapacity: true)
            self.timingSamples.removeAll(keepingCapacity: true)
            self.lastTimingReportUptime = ProcessInfo.processInfo.systemUptime
            self.cadenceDetector.reset()
            self.contentCadenceDetector.reset()
            self.lastContentFrame = nil
            self.lastContentRateReport = 0
            self.onCadenceChanged(nil)
            self.activeBackend = nil
            self.appleProxyInterpolator = nil
            self.processingDisabledError = nil
            self.sessionSetupError = nil
        }
    }

    private func processNext() {
        guard !isProcessing, !pending.isEmpty else { return }
        let input = pending.removeFirst()
        let processStartUptime = ProcessInfo.processInfo.systemUptime
        let queueMilliseconds = max(0, (processStartUptime - input.submittedAtUptime) * 1_000
                                    - input.cadenceMilliseconds)
        if processingDisabledError != nil {
            input.completion(nil, nil, nil)
            processNext()
            return
        }
        if !input.shouldInterpolate {
            if input.repeatedGameFrame {
                onRepeatedGameFrameSkipped()
            }
            input.completion(nil, nil, nil)
            processNext()
            return
        }
        guard let previousBuffer = input.previousBuffer,
              let previousPresentationTimeStamp = input.previousPresentationTimeStamp else {
            input.completion(nil, nil, nil)
            processNext()
            return
        }

        let interval = CMTimeSubtract(input.presentationTimeStamp, previousPresentationTimeStamp)
        let halfInterval = CMTimeGetSeconds(interval) / 2
        let frameDuration = halfInterval.isFinite && halfInterval > 0 && halfInterval < 0.5
            ? halfInterval : nil
        guard let frameDuration else {
            let previousSeconds = CMTimeGetSeconds(previousPresentationTimeStamp)
            let currentSeconds = CMTimeGetSeconds(input.presentationTimeStamp)
            onTimingReport("插帧输入跳过; 原因=时间戳非递增或间隔超出 1 秒; "
                           + String(format: "previousPTS=%.6f; currentPTS=%.6f",
                                    previousSeconds, currentSeconds))
            input.completion(nil, nil, nil)
            processNext()
            return
        }

        let selectedMode = mode
        if selectedMode == .appleLowLatency,
           !canUseAppleLowLatencyFrame(width: CVPixelBufferGetWidth(input.buffer),
                                      height: CVPixelBufferGetHeight(input.buffer),
                                      pixelFormat: CVPixelBufferGetPixelFormatType(input.buffer)) {
            selectBackend("Apple 低延迟插帧不可用（需 1920×1080、受支持的 NV12 格式）")
            input.completion(nil, nil, nil)
            processNext()
            return
        }
        if selectedMode == .appleProxy,
           !canUseAppleProxy(width: CVPixelBufferGetWidth(input.buffer),
                                         height: CVPixelBufferGetHeight(input.buffer),
                                         pixelFormat: CVPixelBufferGetPixelFormatType(input.buffer)) {
            selectBackend("Apple 代理插帧不可用（需至少 1024×576 的 NV12）")
            input.completion(nil, nil, nil)
            processNext()
            return
        }
        if selectedMode == .appleProxy {
            let backendLabel = Self.appleProxyBackendLabel(
                inputWidth: CVPixelBufferGetWidth(input.buffer),
                inputHeight: CVPixelBufferGetHeight(input.buffer))
            selectBackend(backendLabel)
            endVideoToolboxSession()
            let interpolator: AppleDownsampledFrameInterpolator
            do {
                if let existing = appleProxyInterpolator {
                    interpolator = existing
                } else {
                    let created = try AppleDownsampledFrameInterpolator(
                        width: CVPixelBufferGetWidth(input.buffer),
                        height: CVPixelBufferGetHeight(input.buffer),
                        pixelFormat: CVPixelBufferGetPixelFormatType(input.buffer))
                    appleProxyInterpolator = created
                    interpolator = created
                    // 只在新建插帧器时报一次几何关系，避免每帧刷日志。
                    onTimingReport(Self.appleProxyGeometryReport(
                        inputWidth: CVPixelBufferGetWidth(input.buffer),
                        inputHeight: CVPixelBufferGetHeight(input.buffer)))
                }
            } catch {
                fail(input, message: "初始化 Apple 代理插帧失败：\(error.localizedDescription)")
                return
            }
            isProcessing = true
            let providerStartUptime = ProcessInfo.processInfo.systemUptime
            do {
                try interpolator.submit(previous: previousBuffer,
                                        current: input.buffer,
                                        previousPresentationTimeStamp: previousPresentationTimeStamp,
                                        currentPresentationTimeStamp: input.presentationTimeStamp) { result, error in
                    let providerMilliseconds = result?.processingMilliseconds
                        ?? (ProcessInfo.processInfo.systemUptime - providerStartUptime) * 1_000
                    self.queue.async {
                        let errorMessage = error.map { "Apple 代理插帧失败：\(String(describing: $0))" }
                        self.recordTiming(TimingSample(
                            backend: backendLabel,
                            detectedGameFPS: input.detectedGameFPS,
                            gameFrameIntervalMilliseconds: CMTimeGetSeconds(interval) * 1_000,
                            cadenceMilliseconds: input.cadenceMilliseconds,
                            queueMilliseconds: queueMilliseconds,
                            preprocessingMilliseconds: result?.proxyEncodeCPUMilliseconds ?? 0,
                            commandBufferQueueWaitMilliseconds:
                                result?.commandBufferCommitToGPUStartMilliseconds ?? 0,
                            commandBufferGPUExecutionMilliseconds:
                                result?.commandBufferGPUExecutionMilliseconds ?? 0,
                            commandBufferCommitToCompleteMilliseconds:
                                result?.commandBufferCommitToCompleteMilliseconds ?? 0,
                            interpolationSubmitToReadyMilliseconds:
                                result?.interpolationSubmitToReadyMilliseconds ?? 0,
                            providerMilliseconds: providerMilliseconds,
                            appleOrCombinedProcessingMilliseconds:
                                result?.interpolationSubmitToReadyMilliseconds ?? 0,
                            captureToReadyMilliseconds: (ProcessInfo.processInfo.systemUptime
                                                         - input.submittedAtUptime) * 1_000,
                            proxyCacheHits: result?.proxyCacheHits ?? 0,
                            proxyCacheMisses: result?.proxyCacheMisses ?? 0,
                            usedSeparateProcessorSubmission:
                                result?.usedSeparateProcessorSubmission ?? false))
                        if let errorMessage {
                            self.processingDisabledError = errorMessage
                            input.completion(nil, errorMessage, nil)
                        } else if let result {
                            input.completion(result.pixelBuffer, nil, frameDuration)
                        } else {
                            input.completion(nil, "Apple 代理插帧没有生成输出帧", nil)
                        }
                        self.finishCurrentAndContinue()
                    }
                }
            } catch {
                let errorMessage = "Apple 代理插帧失败：\(String(describing: error))"
                processingDisabledError = errorMessage
                input.completion(nil, errorMessage, nil)
                finishCurrentAndContinue()
            }
            return
        }
        selectBackend("Apple VideoToolbox 低延迟插帧（1920×1080）")
        guard ensureSession(for: input.buffer) else {
            fail(input, message: sessionSetupError ?? "系统插帧器无法处理当前格式或尺寸")
            return
        }
        guard let currentFrame = VTFrameProcessorFrame(buffer: input.buffer,
                                                       presentationTimeStamp: input.presentationTimeStamp),
              let previousFrame = VTFrameProcessorFrame(buffer: previousBuffer,
                                                        presentationTimeStamp: previousPresentationTimeStamp) else {
            input.completion(nil, "创建插帧输入帧失败", nil)
            processNext()
            return
        }

        var outputBuffer: CVPixelBuffer?
        let poolStatus = outputPool.map { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, $0, &outputBuffer) }
            ?? kCVReturnInvalidPixelBufferAttributes
        guard poolStatus == kCVReturnSuccess, let outputBuffer else {
            input.completion(nil, "创建插帧输出缓冲失败 status=\(poolStatus)", nil)
            processNext()
            return
        }
        let midpoint = CMTimeAdd(previousFrame.presentationTimeStamp,
                                 CMTimeMultiplyByFloat64(interval, multiplier: 0.5))
        guard let destination = VTFrameProcessorFrame(buffer: outputBuffer,
                                                      presentationTimeStamp: midpoint),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: currentFrame,
                previousFrame: previousFrame,
                interpolationPhase: [0.5],
                destinationFrames: [destination]) else {
            input.completion(nil, "创建插帧参数失败", nil)
            processNext()
            return
        }

        isProcessing = true
        let providerStartUptime = ProcessInfo.processInfo.systemUptime
        processor.process(parameters: parameters) { [weak self] _, error in
            guard let self else { return }
            self.queue.async {
                let providerMilliseconds = (ProcessInfo.processInfo.systemUptime - providerStartUptime) * 1_000
                self.recordTiming(TimingSample(
                    backend: "Apple VideoToolbox 低延迟插帧（1920×1080）",
                    detectedGameFPS: input.detectedGameFPS,
                    gameFrameIntervalMilliseconds: CMTimeGetSeconds(interval) * 1_000,
                    cadenceMilliseconds: input.cadenceMilliseconds,
                    queueMilliseconds: queueMilliseconds,
                    preprocessingMilliseconds: 0,
                    commandBufferQueueWaitMilliseconds: 0,
                    commandBufferGPUExecutionMilliseconds: 0,
                    commandBufferCommitToCompleteMilliseconds: 0,
                    interpolationSubmitToReadyMilliseconds: providerMilliseconds,
                    providerMilliseconds: providerMilliseconds,
                    appleOrCombinedProcessingMilliseconds: providerMilliseconds,
                    captureToReadyMilliseconds: (ProcessInfo.processInfo.systemUptime
                                                 - input.submittedAtUptime) * 1_000,
                    proxyCacheHits: 0,
                    proxyCacheMisses: 0,
                    usedSeparateProcessorSubmission: false))
                let halfInterval = CMTimeGetSeconds(interval) / 2
                let frameDuration = halfInterval.isFinite && halfInterval > 0 && halfInterval < 0.5
                    ? halfInterval : nil
                let processorError: String?
                if let error {
                    let nsError = error as NSError
                    processorError = "VideoToolbox \(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
                } else {
                    processorError = nil
                }
                if let processorError { self.processingDisabledError = processorError }
                input.completion(error == nil ? outputBuffer : nil,
                                 processorError,
                                 frameDuration)
                if processorError != nil {
                    self.endVideoToolboxSession()
                }
                self.finishCurrentAndContinue()
            }
        }
    }

    private func finishCurrentAndContinue() {
        isProcessing = false
        if resetAfterCurrent {
            resetAfterCurrent = false
            endVideoToolboxSession()
        }
        processNext()
    }

    private func fail(_ input: Input, message: String) {
        processingDisabledError = message
        input.completion(nil, message, nil)
        endVideoToolboxSession()
        processNext()
    }

    private func selectBackend(_ label: String) {
        guard activeBackend != label else { return }
        activeBackend = label
        onBackendChanged(label)
    }

    private func recordTiming(_ sample: TimingSample) {
        timingSamples.append(sample)
        if timingSamples.count > 180 {
            timingSamples.removeFirst(timingSamples.count - 180)
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTimingReportUptime >= 3, !timingSamples.isEmpty else { return }
        lastTimingReportUptime = now
        let groups = Dictionary(grouping: timingSamples, by: \.backend)
        for (backend, values) in groups {
            let detectedRates = values.compactMap(\.detectedGameFPS)
            let detectedGameFPS = detectedRates.isEmpty
                ? "未识别"
                : String(format: "%.1f", detectedRates.sorted()[detectedRates.count / 2])
            func percentile(_ select: (TimingSample) -> Double, _ fraction: Double) -> Double {
                let sorted = values.map(select).sorted()
                let index = min(sorted.count - 1,
                                max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
                return sorted[index]
            }
            func range(_ select: (TimingSample) -> Double) -> String {
                String(format: "%.1f/%.1f", percentile(select, 0.50), percentile(select, 0.95))
            }
            let proxyCacheHits = values.reduce(0) { $0 + $1.proxyCacheHits }
            let proxyCacheMisses = values.reduce(0) { $0 + $1.proxyCacheMisses }
            let separateProcessorSubmissions = values.filter(\.usedSeparateProcessorSubmission).count
            onTimingReport("插帧耗时 P50/P95 ms; backend=\(backend); samples=\(values.count); gameFPS=\(detectedGameFPS); gameInterval=\(range(\.gameFrameIntervalMilliseconds)); cadence=\(range(\.cadenceMilliseconds)); queue=\(range(\.queueMilliseconds)); proxyEncodeCPU=\(range(\.preprocessingMilliseconds)); commandBufferQueueWait=\(range(\.commandBufferQueueWaitMilliseconds)); commandBufferGPU=\(range(\.commandBufferGPUExecutionMilliseconds)); commandBufferCommitToComplete=\(range(\.commandBufferCommitToCompleteMilliseconds)); proxyCache=\(proxyCacheHits)/\(proxyCacheMisses); separateProcessorSubmission=\(separateProcessorSubmissions)/\(values.count); interpolationSubmitToReady=\(range(\.interpolationSubmitToReadyMilliseconds)); appleOrCombined=\(range(\.appleOrCombinedProcessingMilliseconds)); provider=\(range(\.providerMilliseconds)); captureToReady=\(range(\.captureToReadyMilliseconds))")
        }
        timingSamples.removeAll(keepingCapacity: true)
    }

    static func appleProxyBackendLabel(inputWidth: Int, inputHeight: Int) -> String {
        guard let proxy = AppleLowLatencyProxySize.best(forWidth: inputWidth, height: inputHeight) else {
            return "Apple 低延迟插帧（代理）"
        }
        if proxy.width == inputWidth, proxy.height == inputHeight {
            return "Apple 低延迟插帧（\(inputWidth)×\(inputHeight) 原生）"
        }
        return "Apple 低延迟插帧（\(inputWidth)×\(inputHeight)→\(proxy.width)×\(proxy.height)代理）"
    }

    /// 记录代理与源帧的几何关系。代理是非等比缩放，显示时按源帧宽高比适配；
    /// 这条日志用来核实两者确实一致（比例闪烁问题的现场证据）。
    static func appleProxyGeometryReport(inputWidth: Int, inputHeight: Int) -> String {
        let sourceAspect = Double(inputWidth) / Double(max(1, inputHeight))
        guard let proxy = AppleLowLatencyProxySize.best(forWidth: inputWidth, height: inputHeight) else {
            return String(format: "代理几何; source=%d×%d aspect=%.4f; proxy=无", inputWidth, inputHeight, sourceAspect)
        }
        let proxyAspect = Double(proxy.width) / Double(proxy.height)
        return String(format: "代理几何; source=%d×%d aspect=%.4f; proxy=%d×%d aspect=%.4f; 插值帧按源宽高比显示",
                      inputWidth, inputHeight, sourceAspect,
                      proxy.width, proxy.height, proxyAspect)
    }

    private func ensureSession(for buffer: CVPixelBuffer) -> Bool {
        sessionSetupError = nil
        let newWidth = CVPixelBufferGetWidth(buffer)
        let newHeight = CVPixelBufferGetHeight(buffer)
        let newPixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        if sessionStarted, width == newWidth, height == newHeight, pixelFormat == newPixelFormat {
            return true
        }
        endVideoToolboxSession()
        if #available(macOS 27.0, *) {
            let maximumDimension = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1) ?? 0
            let maximumPixelCount = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1) ?? 0
            guard maximumDimension > 0, maximumPixelCount > 0,
                  newWidth <= maximumDimension, newHeight <= maximumDimension,
                  newWidth * newHeight <= maximumPixelCount else {
                sessionSetupError = "VideoToolbox 插帧尺寸超出本机上限；当前缓冲为 \(newWidth)×\(newHeight)"
                return false
            }
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: newWidth, frameHeight: newHeight, numberOfInterpolatedFrames: 1) else {
            sessionSetupError = "本机 VideoToolbox 不支持插帧配置"
            return false
        }
        guard config.supportedPixelFormats.contains(newPixelFormat) else {
            sessionSetupError = "VideoToolbox 不支持输入像素格式 \(MetalRenderer.fourcc(newPixelFormat))"
            return false
        }
        let destinationFormat = (config.destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
        guard destinationFormat == newPixelFormat else {
            sessionSetupError = "插帧器输出像素格式与采集缓冲不匹配"
            return false
        }
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                      config.destinationPixelBufferAttributes as CFDictionary,
                                      &pool) == kCVReturnSuccess,
              let pool else { return false }
        let sessionProcessor = VTFrameProcessor()
        do {
            try sessionProcessor.startSession(configuration: config)
        } catch {
            sessionSetupError = "启动 VideoToolbox 插帧会话失败：\(error.localizedDescription)"
            return false
        }
        // Give every session a fresh processor so end/start cycles cannot reuse
        // stale VideoToolbox pipeline state.
        processor = sessionProcessor
        width = newWidth
        height = newHeight
        pixelFormat = newPixelFormat
        frameConfig = config
        outputPool = pool
        sessionStarted = true
        return true
    }

    private func endVideoToolboxSession() {
        if sessionStarted { processor.endSession() }
        sessionStarted = false
        outputPool = nil
        frameConfig = nil
        width = 0
        height = 0
        pixelFormat = 0
    }
}

/// Where video frames come from. Both sources feed `handleVideoFrame`.
