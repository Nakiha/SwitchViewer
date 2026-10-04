import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

extension AppDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
    func recordDisplayPresentation(_ frame: PresentationFrame, presentedTime: CFTimeInterval) {
        let wasPresented = presentedTime.isFinite && presentedTime > 0
        if wasPresented, let time = frame.presentationTimestampHostTime {
            comparisonRecorder.append(frame.pixelBuffer, track: .processed, hostTime: time,
                generated: frame.isInterpolated, referenceAspect: frame.referenceAspect.map(Double.init))
        }
        let timing = frame.timing
        let sample = DisplayLatencySample(
            isInterpolated: frame.isInterpolated,
            callbackToDisplayMilliseconds: wasPresented
                ? timing.callbackToDisplayMilliseconds(presentedTime) : nil,
            mediaTimestampToDisplayMilliseconds: wasPresented
                ? frame.presentationTimestampHostTime.map { (presentedTime - $0) * 1_000 } : nil,
            callbackToReadyMilliseconds: timing.callbackToReadyMilliseconds(),
            readyToPresentationEnqueueMilliseconds: timing.milliseconds(from: .processingReady,
                                                                       to: .presentationEnqueued),
            presentationQueueWaitMilliseconds: timing.milliseconds(from: .presentationEnqueued,
                                                                   to: .presentationQueueStarted),
            queueStartToDrawableMilliseconds: timing.milliseconds(from: .presentationQueueStarted,
                                                                  to: .drawableAcquired),
            drawableWaitMilliseconds: timing.milliseconds(from: .drawableWaitStarted,
                                                          to: .drawableAcquired),
            drawableToCommitMilliseconds: timing.milliseconds(from: .drawableAcquired,
                                                              to: .commandBufferSubmitStarted),
            gpuSubmitToCompleteMilliseconds: timing.milliseconds(from: .commandBufferSubmitStarted,
                                                                to: .gpuCompleted),
            gpuCompleteToDisplayMilliseconds: wasPresented
                ? timing.milliseconds(from: .gpuCompleted, toHostTime: presentedTime) : nil,
            targetToPresentedMilliseconds: wasPresented
                ? frame.targetPresentationHostTime.map { (presentedTime - $0) * 1_000 } : nil)
        if wasPresented, frame.sourceID != nil {
            presentationScheduler.recordSourcePresented(
                frame.sourceID, contentRootID: frame.sourceContentRootID)
            screenPresentationScheduler.recordSourcePresented(
                frame.sourceID, contentRootID: frame.sourceContentRootID)
        }
        if let lead = timing.milliseconds(from: .presentationQueueStarted, to: .gpuCompleted) {
            presentationScheduler.recordRendererLead(lead)
            screenPresentationScheduler.recordRendererLead(lead)
        }
        displayTimingQueue.async { [self] in
            self.displayTimingSamples.append(sample)
            if wasPresented {
                self.shownFrameTimes.append(presentedTime)
                if frame.isInterpolated { self.shownMidpointCount += 1 }
            }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastDisplayTimingReportUptime >= 3,
                  !self.displayTimingSamples.isEmpty else { return }
            let samples = self.displayTimingSamples
            let elapsed = now - self.lastDisplayTimingReportUptime
            let uniqueShown = Set(self.shownFrameTimes.map { Int64(($0 * 1_000_000).rounded()) }).count
            let sourceFPS = Double(self.capturedSourceCount) / max(0.001, elapsed)
            self.capturedSourceCount = 0
            self.diagnosticLog.append("实际显示帧率; windowSeconds=\(String(format: "%.2f", elapsed)); displayedFPS=\(String(format: "%.1f", Double(uniqueShown) / max(0.001, elapsed))); shownFrames=\(uniqueShown); shownMidpoints=\(self.shownMidpointCount)")
            self.shownFrameTimes.removeAll(keepingCapacity: true)
            self.shownMidpointCount = 0
            self.displayTimingSamples.removeAll(keepingCapacity: true)
            self.lastDisplayTimingReportUptime = now

            func percentile(_ values: [Double], _ fraction: Double) -> Double? {
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                let index = min(sorted.count - 1,
                                max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
                return sorted[index]
            }
            func range(_ values: [Double]) -> String {
                guard let p50 = percentile(values, 0.50),
                      let p95 = percentile(values, 0.95),
                      let p99 = percentile(values, 0.99) else { return "无" }
                return String(format: "%.1f/%.1f/%.1f", p50, p95, p99)
            }
            func stageRange(_ keyPath: KeyPath<DisplayLatencySample, Double?>,
                            in values: [DisplayLatencySample]) -> String {
                range(values.compactMap { $0[keyPath: keyPath] })
            }

            let ages = samples.compactMap(\.callbackToDisplayMilliseconds)
            let processing = samples.compactMap(\.callbackToReadyMilliseconds)
            let waits = samples.compactMap { sample -> Double? in
                guard let total = sample.callbackToDisplayMilliseconds, let ready = sample.callbackToReadyMilliseconds else { return nil }
                return max(0, total - ready)
            }
            if let p50 = percentile(ages, 0.5), let p95 = percentile(ages, 0.95),
               let ready = percentile(processing, 0.5), let wait = percentile(waits, 0.5) {
                var metrics = PerformanceMetrics(fps: Double(uniqueShown) / max(0.001, elapsed), latency: p50,
                                                 p95: p95, processing: ready, wait: wait)
                metrics.sourceFPS = sourceFPS
                self.frameLock.lock()
                metrics.detectedContentFPS = self.frameInterpolationEnabled ? self.observedContentFPS : nil
                self.frameLock.unlock()
                metrics.drawableWait = percentile(samples.compactMap(\.drawableWaitMilliseconds), 0.5)
                metrics.gpu = percentile(samples.compactMap(\.gpuSubmitToCompleteMilliseconds), 0.5)
                metrics.compositor = percentile(samples.compactMap(\.gpuCompleteToDisplayMilliseconds), 0.5)
                let snapshot = metrics
                DispatchQueue.main.async { [weak self] in self?.gameInjectionController.receiveScreenMetrics(snapshot) }
            }

            for isInterpolated in [true, false] {
                let group = samples.filter { $0.isInterpolated == isInterpolated }
                guard !group.isEmpty else { continue }
                let shown = group.filter { $0.callbackToDisplayMilliseconds != nil }
                let callbackLatency = shown.compactMap(\.callbackToDisplayMilliseconds)
                let mediaLatency = shown.compactMap(\.mediaTimestampToDisplayMilliseconds)
                self.diagnosticLog.append(
                    "实际上屏分段 P50/P95/P99 ms; frame=\(isInterpolated ? "插值帧" : "采集帧"); samples=\(group.count); presented=\(shown.count); callbackToDisplay=\(range(callbackLatency)); mediaTimestampToDisplay=\(range(mediaLatency)); callbackToReady=\(stageRange(\.callbackToReadyMilliseconds, in: group)); readyToEnqueue=\(stageRange(\.readyToPresentationEnqueueMilliseconds, in: group)); presentationQueueWait=\(stageRange(\.presentationQueueWaitMilliseconds, in: group)); queueStartToDrawable(includesNextDrawableWait)=\(stageRange(\.queueStartToDrawableMilliseconds, in: group)); nextDrawableWait=\(stageRange(\.drawableWaitMilliseconds, in: group)); drawableToSubmit=\(stageRange(\.drawableToCommitMilliseconds, in: group)); gpuSubmitToComplete=\(stageRange(\.gpuSubmitToCompleteMilliseconds, in: group)); gpuCompleteToDisplay=\(stageRange(\.gpuCompleteToDisplayMilliseconds, in: group)); targetToPresented=\(stageRange(\.targetToPresentedMilliseconds, in: group))")
            }
        }
    }

    func recordCaptureCallbackTiming(ptsToCallbackMilliseconds: Double?,
                                             callbackWorkMilliseconds: Double,
                                             signatureSamplingMilliseconds: Double?) {
        captureCallbackTimingQueue.async {
            self.captureCallbackTimingSamples.append(CaptureCallbackTimingSample(
                ptsToCallbackMilliseconds: ptsToCallbackMilliseconds,
                callbackWorkMilliseconds: callbackWorkMilliseconds,
                signatureSamplingMilliseconds: signatureSamplingMilliseconds))
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastCaptureCallbackTimingReportUptime >= 3,
                  !self.captureCallbackTimingSamples.isEmpty else { return }
            let samples = self.captureCallbackTimingSamples
            self.captureCallbackTimingSamples.removeAll(keepingCapacity: true)
            self.lastCaptureCallbackTimingReportUptime = now

            func percentile(_ values: [Double], _ fraction: Double) -> Double? {
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                let index = min(sorted.count - 1,
                                max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
                return sorted[index]
            }
            func range(_ values: [Double]) -> String {
                guard let p50 = percentile(values, 0.50),
                      let p95 = percentile(values, 0.95),
                      let p99 = percentile(values, 0.99) else { return "无" }
                return String(format: "%.1f/%.1f/%.1f", p50, p95, p99)
            }
            self.diagnosticLog.append(
                "采集回调耗时 P50/P95/P99 ms; samples=\(samples.count); ptsToCallback=\(range(samples.compactMap(\.ptsToCallbackMilliseconds))); signatureSampling=\(range(samples.compactMap(\.signatureSamplingMilliseconds))); callbackWork=\(range(samples.map(\.callbackWorkMilliseconds)))")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 屏幕捕获接管期间采集卡可能还会投递少量在途帧，直接丢弃。
        guard videoSource == .captureCard else { return }
        let callbackWorkStart = ProcessInfo.processInfo.systemUptime
        var ptsToCallbackMilliseconds: Double?
        var signatureSamplingMilliseconds: Double?
        defer {
            let callbackWorkMilliseconds = (ProcessInfo.processInfo.systemUptime - callbackWorkStart) * 1_000
            recordCaptureCallbackTiming(ptsToCallbackMilliseconds: ptsToCallbackMilliseconds,
                                        callbackWorkMilliseconds: callbackWorkMilliseconds,
                                        signatureSamplingMilliseconds: signatureSamplingMilliseconds)
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureCallbackHostTime = presentationHostTimeNow()
        let presentationTimestampHostTime = hostTime(forCaptureTimestamp: presentationTimeStamp)
        if let presentationTimestampHostTime,
           captureCallbackHostTime >= presentationTimestampHostTime {
            ptsToCallbackMilliseconds = (captureCallbackHostTime - presentationTimestampHostTime) * 1_000
        }
        signatureSamplingMilliseconds = handleVideoFrame(
            pixelBuffer: pb,
            presentationTimeStamp: presentationTimeStamp,
            captureCallbackHostTime: captureCallbackHostTime,
            presentationTimestampHostTime: presentationTimestampHostTime)
    }

    /// Source-agnostic frame entry point shared by the capture card and screen
    /// capture. Returns the display-signature sampling cost for timing reports.
    @discardableResult
    func handleVideoFrame(pixelBuffer pb: CVPixelBuffer,
                          presentationTimeStamp: CMTime,
                          captureCallbackHostTime: CFTimeInterval,
                          presentationTimestampHostTime: CFTimeInterval?) -> Double? {
        if let time = presentationTimestampHostTime {
            comparisonRecorder.append(pb, track: .original, hostTime: time)
        }
        displayTimingQueue.async { [weak self] in self?.capturedSourceCount += 1 }
        var signatureSamplingMilliseconds: Double?
        let pf = CVPixelBufferGetPixelFormatType(pb)
        frameLock.lock()
        let changed = lastWidth != CVPixelBufferGetWidth(pb)
            || lastHeight != CVPixelBufferGetHeight(pb)
            || lastPixelFormat != pf
        lastPixelFormat = pf
        lastWidth = CVPixelBufferGetWidth(pb)
        lastHeight = CVPixelBufferGetHeight(pb)
        lastFrameDate = Date()
        let interpolationEnabled = frameInterpolationEnabled
        let interpolationEngine = frameInterpolationEngine
        let interpolationMode = frameInterpolationMode
        let pacingMode = presentationPacingMode
        let contentTimed = videoSource == .screen
        let deadlineCadenceActive = self.deadlineCadenceActive
        let epoch = frameInterpolationEpoch
        let sourceGeneration = sessionGeneration
        frameLock.unlock()
        if changed {
            diagnosticLog.append("收到视频帧格式变化; buffer=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)); pixelFormat=\(fourccString(pf))")
            DispatchQueue.main.async {
                self.updateAppleLowLatencyMenuAvailability()
                self.applyPendingInterpolationIfNeeded()
                if self.frameInterpolationMode == .appleLowLatency
                    || self.frameInterpolationMode == .appleProxy {
                    self.frameLock.lock()
                    let interpolationEnabled = self.frameInterpolationEnabled
                    let width = self.lastWidth
                    let height = self.lastHeight
                    let pixelFormat = self.lastPixelFormat
                    self.frameLock.unlock()
                    let available = self.frameInterpolationMode == .appleLowLatency
                        ? canUseAppleLowLatencyFrame(width: width, height: height, pixelFormat: pixelFormat)
                        : canUseAppleProxy(width: width, height: height, pixelFormat: pixelFormat)
                    if interpolationEnabled && !available {
                        self.setStatus(self.frameInterpolationMode == .appleLowLatency
                            ? "Apple 原生低延迟插帧只接受 1920×1080 NV12；当前分辨率按原帧显示"
                            : "Apple 代理插帧至少需要 1024×576 NV12；当前分辨率按原帧显示",
                                       base: false)
                    }
                }
            }
        }
        let signatureStartUptime = ProcessInfo.processInfo.systemUptime
        let displaySignature = interpolationEnabled
            ? SwitchFrameCadenceDetector.makeDisplayFrameSignature(from: pb) : nil
        if interpolationEnabled {
            signatureSamplingMilliseconds = (ProcessInfo.processInfo.systemUptime
                                             - signatureStartUptime) * 1_000
        }
        let contentFPS = interpolationEnabled ? contentFrameRateMonitor.observe(pb, signature: displaySignature,
            time: CMTimeGetSeconds(presentationTimeStamp), captureCadence: !contentTimed,
            generation: epoch) : nil
        frameLock.lock()
        if sourceGeneration == sessionGeneration && epoch == frameInterpolationEpoch { observedContentFPS = contentFPS }
        frameLock.unlock()
        if interpolationEnabled && contentTimed {
            frameLock.lock()
            let content = screenContentDetector.observe(signature: displaySignature,
                                                        time: CMTimeGetSeconds(presentationTimeStamp))
            if content.isDuplicate { interpolationRepeatedFrameSkipCount += 1 }
            frameLock.unlock()
            if content.isDuplicate { return signatureSamplingMilliseconds }
        }
        if interpolationEnabled,
           (contentTimed || (interpolationMode == .appleProxy &&
                            pacingMode == .deadlineScheduled && deadlineCadenceActive)),
           let interpolationEngine,
           let presentationTimestampHostTime {
            frameLock.lock()
            nextSourceFrameID &+= 1
            let sourceID = nextSourceFrameID
            frameLock.unlock()
            let scheduler = contentTimed ? screenPresentationScheduler : presentationScheduler
            scheduler.offerSource(CapturedSourceFrame(
                id: sourceID,
                pixelBuffer: pb,
                signature: displaySignature,
                presentationTimeStamp: presentationTimeStamp,
                mediaHostTime: presentationTimestampHostTime,
                captureCallbackHostTime: captureCallbackHostTime,
                epoch: epoch))
            let interpolationSubmittedHostTime = presentationHostTimeNow()
            interpolationEngine.submit(pb,
                                       presentationTimeStamp: presentationTimeStamp,
                                       displaySignature: displaySignature,
                                       contentTimed: contentTimed) {
                [weak self] generated, error, halfInterval in
                guard let self else { return }
                if let error, self.canPresentFrame(epoch: epoch, requireInterpolation: true) {
                    self.recordInterpolationFailure(error)
                }
                guard self.canPresentFrame(epoch: epoch, requireInterpolation: true),
                      let generated,
                      let halfInterval, halfInterval > 0 else { return }
                let midpointPresentationTimeStamp = CMTimeSubtract(
                    presentationTimeStamp,
                    CMTime(seconds: halfInterval, preferredTimescale: 60_000))
                guard let midpointHostTime = self.hostTime(
                    forCaptureTimestamp: midpointPresentationTimeStamp) else {
                    self.diagnosticLog.append("deadline 插值帧丢弃; 原因=媒体时间戳无法转换到 host time")
                    return
                }
                let previousSourcePresentationTimeStamp = CMTimeSubtract(
                    midpointPresentationTimeStamp,
                    CMTime(seconds: halfInterval, preferredTimescale: 60_000))
                let readyHostTime = presentationHostTimeNow()
                scheduler.offerMidpoint(InterpolatedFrame(
                    previousSourcePresentationTimeStamp: previousSourcePresentationTimeStamp,
                    currentSourceID: sourceID,
                    pixelBuffer: generated,
                    sourceAspect: Self.aspectRatio(of: pb),
                    mediaPresentationTimeStamp: midpointPresentationTimeStamp,
                    mediaHostTime: midpointHostTime,
                    captureCallbackHostTime: captureCallbackHostTime,
                    submittedHostTime: interpolationSubmittedHostTime,
                    readyHostTime: readyHostTime,
                    epoch: epoch))
            }
        } else if interpolationEnabled, let interpolationEngine {
            interpolationEngine.submit(pb,
                                       presentationTimeStamp: presentationTimeStamp,
                                       displaySignature: displaySignature,
                                       contentTimed: false) {
                [weak self] generated, error, halfInterval in
                guard let self else { return }
                if let error, self.canPresentFrame(epoch: epoch, requireInterpolation: true) {
                    self.recordInterpolationFailure(error)
                }
                self.enqueueInterpolatedFrames(generated: generated, source: pb,
                                               sourceDisplaySignature: displaySignature,
                                               sourcePresentationTimeStamp: presentationTimeStamp,
                                               sourceTimestampHostTime: presentationTimestampHostTime,
                                               captureCallbackHostTime: captureCallbackHostTime,
                                               halfInterval: halfInterval, epoch: epoch)
            }
        } else {
            enqueuePresentationFrames([
                PresentationFrame(pixelBuffer: pb, isInterpolated: false,
                                  minimumPresentationDuration: nil,
                                  presentationTimestampHostTime: presentationTimestampHostTime,
                                  timing: PresentationFrameTiming(
                                    captureCallbackHostTime: captureCallbackHostTime))
            ], epoch: epoch, requireInterpolation: false)
        }
        return signatureSamplingMilliseconds
    }

    func enqueueInterpolatedFrames(generated: CVPixelBuffer?, source: CVPixelBuffer,
                                   sourceDisplaySignature: DisplayFrameSignature?,
                                   sourcePresentationTimeStamp: CMTime,
                                   sourceTimestampHostTime: CFTimeInterval?,
                                   captureCallbackHostTime: CFTimeInterval,
                                   halfInterval: TimeInterval?, epoch: Int) {
        var frames: [PresentationFrame] = []
        frameLock.lock()
        let pacingMode = presentationPacingMode
        frameLock.unlock()
        let minimumPresentationDuration = pacingMode.minimumDuration(for: halfInterval)
        let processingReadyHostTime = presentationHostTimeNow()
        if let generated {
            let generatedPresentationTimeStamp: CMTime
            if let halfInterval, halfInterval > 0 {
                generatedPresentationTimeStamp = CMTimeSubtract(
                    sourcePresentationTimeStamp,
                    CMTime(seconds: halfInterval, preferredTimescale: 60_000))
            } else {
                generatedPresentationTimeStamp = sourcePresentationTimeStamp
            }
            frames.append(PresentationFrame(
                pixelBuffer: generated,
                isInterpolated: true,
                minimumPresentationDuration: minimumPresentationDuration,
                presentationTimestampHostTime: hostTime(forCaptureTimestamp: generatedPresentationTimeStamp),
                referenceAspect: Self.aspectRatio(of: source),
                timing: PresentationFrameTiming(
                    captureCallbackHostTime: captureCallbackHostTime,
                    processingReadyHostTime: processingReadyHostTime)))
        }
        frames.append(PresentationFrame(pixelBuffer: source,
                                        displaySignature: sourceDisplaySignature,
                                        isInterpolated: false,
                                        minimumPresentationDuration: generated == nil
                                            ? nil : minimumPresentationDuration,
                                        presentationTimestampHostTime: sourceTimestampHostTime,
                                        timing: PresentationFrameTiming(
                                            captureCallbackHostTime: captureCallbackHostTime,
                                            processingReadyHostTime: processingReadyHostTime)))
        enqueuePresentationFrames(frames, epoch: epoch, requireInterpolation: true)
    }

    /// 显示时使用的宽高比。插值帧必须沿用其源帧的，否则代理的非等比缩放会露出来。
    static func aspectRatio(of buffer: CVPixelBuffer) -> Float {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        return Float(width) / Float(max(1, height))
    }

    func enqueuePresentationFrames(_ frames: [PresentationFrame],
                                  epoch: Int, requireInterpolation: Bool) {
        guard canPresentFrame(epoch: epoch, requireInterpolation: requireInterpolation) else { return }
        var candidates = frames
        if requireInterpolation,
           let sourceFrame = frames.first(where: { !$0.isInterpolated }),
           sourceFrame.sourceID == nil {
            frameLock.lock()
            let previousSignature = lastAcceptedSourceSignature
            frameLock.unlock()
            if let previousSignature, let currentSignature = sourceFrame.displaySignature {
                let compareStart = ProcessInfo.processInfo.systemUptime
                let isIdentical = previousSignature == currentSignature
                let compareMilliseconds = (ProcessInfo.processInfo.systemUptime - compareStart) * 1_000
                frameLock.lock()
                signatureCompareCount += 1
                signatureCompareTotalMilliseconds += compareMilliseconds
                signatureCompareMaxMilliseconds = max(signatureCompareMaxMilliseconds,
                                                      compareMilliseconds)
                if isIdentical { signatureDuplicateSourceCount += 1 }
                frameLock.unlock()
                if isIdentical {
                    // The layer keeps the last drawable visible. Only suppress a source
                    // frame when the sampled luma/chroma signature is unchanged.
                    candidates.removeAll { !$0.isInterpolated }
                }
            }
        }
        guard !candidates.isEmpty else { return }
        var admitted: [PresentationFrame] = []
        for frame in candidates {
            if presentationSlots.wait(timeout: .now()) == .success {
                admitted.append(frame)
            } else {
                break
            }
        }
        if candidates.count == 2, admitted.count == 1, admitted[0].isInterpolated {
            admitted[0] = candidates[1]
        }
        let omittedCount = candidates.count - admitted.count
        if omittedCount > 0 {
            frameLock.lock()
            droppedCount += omittedCount
            presentationLimitDropCount += omittedCount
            frameLock.unlock()
        }
        if admitted.isEmpty { return }
        if let source = admitted.last(where: { !$0.isInterpolated }) {
            frameLock.lock()
            lastAcceptedSourceSignature = source.displaySignature
            frameLock.unlock()
        }
        for frame in admitted { frame.timing.mark(.presentationEnqueued) }
        presentationQueue.async {
            guard self.canPresentFrame(epoch: epoch, requireInterpolation: requireInterpolation) else {
                for _ in admitted { self.presentationSlots.signal() }
                return
            }
            for frame in admitted {
                frame.timing.mark(.presentationQueueStarted)
                self.presentPixelBuffer(frame,
                                       epoch: epoch, requireInterpolation: requireInterpolation,
                                       onPresented: { self.presentationSlots.signal() })
            }
        }
    }

    func canPresentFrame(epoch: Int, requireInterpolation: Bool) -> Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return frameInterpolationEpoch == epoch
            && (!requireInterpolation || frameInterpolationEnabled)
            && !screenOutputSuspended
    }

    func recordInterpolationFailure(_ message: String) {
        frameLock.lock()
        interpolationFailureCount += 1
        let shouldLog = lastInterpolationError != message
        lastInterpolationError = message
        let shouldDisable = frameInterpolationEnabled
        if shouldDisable {
            frameInterpolationEnabled = false
            frameInterpolationEpoch += 1
            frameInterpolationUnavailable = true
            clearDeadlineCadenceQualificationLocked()
        }
        let epoch = frameInterpolationEpoch
        let interpolationEngine = frameInterpolationEngine
        frameLock.unlock()
        if shouldLog { diagnosticLog.append("插帧失败; error=\(message)") }
        if shouldDisable {
            presentationScheduler.reset(epoch: epoch)
            resetScreenTiming(epoch: epoch)
            interpolationEngine?.reset()
            DispatchQueue.main.async {
                self.frameInterpolationMenuItem?.state = .off
                self.frameInterpolationMenuItem?.title = "插帧不可用（已自动关闭）"
                self.frameInterpolationMenuItem?.isEnabled = false
                self.setStatus("VideoToolbox 插帧失败，已自动关闭：\(message)", base: false)
            }
        }
    }

    func presentPixelBuffer(_ frame: PresentationFrame,
                            epoch: Int, requireInterpolation: Bool,
                            onPresented: @escaping () -> Void) {
        guard canPresentFrame(epoch: epoch, requireInterpolation: requireInterpolation) else {
            onPresented()
            return
        }
        guard let r = renderer else {
            frameLock.lock()
            droppedCount += 1
            rendererFailureCount += 1
            let errorMessage = "Metal 未初始化：\(metalInitError ?? "?")"
            let firstError = !didLogRenderFailure
            if firstError {
                didLogRenderFailure = true
                if firstRenderError == nil { firstRenderError = errorMessage }
                lastRenderError = errorMessage
            }
            frameLock.unlock()
            if firstError { diagnosticLog.append("渲染错误; \(errorMessage)") }
            onPresented()
            return
        }
        frameLock.lock()
        let softenSource = uniformProxyFrames && frameInterpolationEnabled
            && frameInterpolationMode == .appleProxy && !frame.isInterpolated
        frameLock.unlock()
        let (ok, err) = r.render(pixelBuffer: frame.pixelBuffer,
                                 referenceAspect: frame.referenceAspect,
                                 softenSource: softenSource,
                                 minimumPresentationDuration: frame.minimumPresentationDuration,
                                 targetPresentationHostTime: frame.targetPresentationHostTime,
                                 onPresented: { [weak self] presentedTime in
            self?.recordDisplayPresentation(frame, presentedTime: presentedTime)
            onPresented()
        },
                                 onDrawableWaitStarted: {
            frame.timing.mark(.drawableWaitStarted)
        },
                                 onDrawableAcquired: {
            frame.timing.mark(.drawableAcquired)
        },
                                 onCommandBufferCommitted: {
            frame.timing.mark(.commandBufferSubmitStarted)
        },
                                 onGPUCompleted: {
            frame.timing.mark(.gpuCompleted)
        })
        frameLock.lock()
        if ok {
            lastPixelBuffer = frame.pixelBuffer
            frameCount += 1
            if frame.isInterpolated { interpolatedFrameCount += 1 }
            consecFails = 0
        } else {
            droppedCount += 1
            rendererFailureCount += 1
            consecFails += 1
            let firstError = !didLogRenderFailure
            if firstError {
                didLogRenderFailure = true
                firstRenderError = err
            }
            lastRenderError = err
            let cf = consecFails
            frameLock.unlock()
            if firstError { diagnosticLog.append("Metal 渲染失败; error=\(err ?? "未知"); consecutiveFailures=\(cf)") }
            if cf == 30 { enableFallback(err ?? "未知错误") }
            onPresented()
            return
        }
        frameLock.unlock()
    }
}
