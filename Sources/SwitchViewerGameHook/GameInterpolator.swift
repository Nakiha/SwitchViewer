import AppKit
import CoreMedia
import CoreVideo
import GameMetalHook
import Metal
import QuartzCore
import SwitchViewerInterpolation
import SwitchViewerRecording

@available(macOS 26.0, *)
final class GameInterpolator {
    static let shared = GameInterpolator()
    private let lock = NSLock()
    private let work = DispatchQueue(label: "switchviewer.game-interpolation", qos: .userInteractive)
    private lazy var drawablePool = GameDrawablePool(trace: frameTrace, startedAt: startedAt,
        injectStall: ProcessInfo.processInfo.processName == "GameHookFixture"
            && CommandLine.arguments.contains("--drawable-stall-test"))
    /// 逐帧埋点：环形缓冲 + 停顿倒带 + 每条静默路径的计数器。
    private let trace = FrameStallTrace()
    func overlayPresentRequest(sequence: UInt64, time: Double, requested: Double, mode: Int32) {
        var event = GameFrameTrace.Event("drawablePresentCalled", sequence: sequence, time: time)
        event.requested = requested
        event.reason = mode == 1 ? "atTime" : (mode == 2 ? "minimumDuration" : "immediate")
        frameTrace.record(event)
    }
    private let frameTrace = GameFrameTrace()
    private let traceOutput = DispatchQueue(label: "switchviewer.frame-trace", qos: .utility)
    private var traceTimer: DispatchSourceTimer?
    private let presentationObserver = PresentationTraceObserver()

    func startFrameTrace() {
        let id = frameTrace.begin(at: CACurrentMediaTime())
        report("FRAME_TRACE begin id=\(id) schema=3 duration=30")
        recordDisplayState()
        guard traceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: traceOutput)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(20))
        timer.setEventHandler { [self] in
            let batch = frameTrace.takeBatch()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for event in batch.events {
                if let data = try? encoder.encode(event), let line = String(data: data, encoding: .utf8) {
                    report("FRAME " + line)
                }
            }
            if batch.lost > 0 { report("FRAME_TRACE lost=\(batch.lost)") }
            if !frameTrace.isRecording(at: CACurrentMediaTime()) {
                DispatchQueue.main.async { [self] in
                    guard !frameTrace.isRecording(at: CACurrentMediaTime()) else { return }
                    presentationObserver.stop()
                    traceTimer?.cancel()
                    traceTimer = nil
                    report("FRAME_TRACE end")
                }
            }
        }
        traceTimer = timer
        timer.resume()
    }
    lazy var comparisonRecorder = ComparisonMovieRecorder { event in
        switch event {
        case .started(let url):
            report("MOVIE_RECORD begin path=" + Data(url.path.utf8).base64EncodedString())
        case .finishing: report("MOVIE_RECORD finishing")
        case .finished(let url):
            report("MOVIE_RECORD end path=" + Data(url.path.utf8).base64EncodedString())
        case .failed(let message):
            report("MOVIE_RECORD failed detail=" + Data(message.utf8).base64EncodedString())
        }
    }
    func startComparisonRecording() {
        lock.lock(); let paused = originalView; lock.unlock()
        guard !paused else { report("MOVIE_RECORD failed detail=" + Data("请先开启插帧".utf8).base64EncodedString()); return }
        let root = ProcessInfo.processInfo.processName == "GameHookFixture"
            ? ProcessInfo.processInfo.environment["SWITCHVIEWER_COMPARISON_RECORDING_ROOT"].map { URL(fileURLWithPath: $0) }
            : nil
        comparisonRecorder.start(root: root ?? ComparisonMovieRecorder.gameRecordingsDirectory())
    }

    private var lastAcceptedNativeRequest: Double = 0 // Protected by lock.
    private var nextCaptureID: UInt64 = 0 // Protected by lock.
    // Main queue only; counts callbacks awaiting main-queue accounting, not
    // GPU queue depth or a guarantee of visible pixels.
    private var pendingPresentation: Set<UInt64> = []
    private var pendingGPU: Set<UInt64> = []
    private var pendingAcquisition: Int { drawablePool.pendingAcquisition }
    private var busy = false
    // Worker queue only: capture can continue while one Apple job is in flight.
    private var interpolationBusy = false
    private var captureTexture: MTLTexture?
    private var originalView = false
    private weak var sourceLayer: CAMetalLayer?
    private var converter: GameFrameColorConverter?
    private var renderQueue: MTLCommandQueue?
    private var interpolator: AppleDownsampledFrameInterpolator?
    private var previous: CVPixelBuffer?
    private var previousTime: Double = 0
    private var previousSequence: UInt64 = 0
    private var preparedPreviousPlan: GameFramePlayoutPlanner.Plan?
    private let interpolationOptions = InterpolationOptions.from(environment: ProcessInfo.processInfo.environment)
    private var multiFrameDelay = MultiFrameDelayController()
    private var pressure = GameFramePressureController()
    private var lastPressureReport: Double = 0
    private var lastTraceReport = CACurrentMediaTime()
    private var phaseShown = 0
    private var phaseDropped = 0
    private let startedAt = CACurrentMediaTime()
    private var pressureGeneration = 0
    private var geometry = CGSize.zero
    private var epoch = 0
    private var generated = 0
    private var lastReport: Double = 0
    private var playout = GameFramePlayoutPlanner()
    private var pairSequence: UInt64 = 0
    // Only accessed on the main queue.
    private var overlay: CAMetalLayer?
    private var presentationEpoch = 0
    private let hookConfiguration = GameHookConfiguration()
    private let submissions = GameFrameSubmissionQueue(now: { CACurrentMediaTime() }, schedule: { time, task in
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, time - CACurrentMediaTime()), execute: task)
    }, deferTask: { task in DispatchQueue.main.async(execute: task) })
    private var lastReadyTime: Double = 0
    private var interpolationFailed = false
    private var watchdog: Timer?
    private struct DisplaySample {
        let age: Double
        let readyWait: Double
        let processing: Double?
        let interval: Double
        let original: Bool
        let presentedTime: Double
        let sequence: UInt64
        let submitAge: Double
        let targetError: Double
        let drawableWait: Double
        let gpu: Double?
        let compositor: Double?
    }
    private final class DeliveryFeedback {
        private let lock = NSLock()
        private var callback: ((Bool) -> Void)?
        init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
        func finish(_ shown: Bool) {
            lock.lock(); let callback = self.callback; self.callback = nil; lock.unlock()
            callback?(shown)
        }
    }
    private final class RenderTiming {
        private let lock = NSLock()
        private var completion: Double?
        func complete(_ time: Double) { lock.lock(); completion = time; lock.unlock() }
        func read() -> Double? { lock.lock(); defer { lock.unlock() }; return completion }
    }
    private var samples: [DisplaySample] = []
    private var processingSamples: [Double] = []
    private var metricsStart = CACurrentMediaTime()
    // Protected by lock; counts game submissions even when interpolation is busy.
    private var sourceFrameRate = SourceFrameRateCounter(startTime: CACurrentMediaTime())
    private var metricPresentedTimes: Set<Int64> = []
    private var displayPresentedTimes: Set<Int64> = []
    private var displayReportTime = CACurrentMediaTime()
    private var displayGraceDeadline: Double = 0
    private var retryDisplayAfter: Double = 0

    func capture(buffer: MTLCommandBuffer, drawable: CAMetalDrawable, layer: CAMetalLayer,
                 nativeRequestTime: Double, nativePresentedTime: Double, nativeCallbackTime: Double, nativeGPUTime: Double) -> UInt64 {
        trace.count(.captureEntered)
        lock.lock()
        var captureID: UInt64 = 0
        if sourceLayer == nil || sourceLayer === layer {
            let time = CACurrentMediaTime()
            nextCaptureID += 1
            captureID = nextCaptureID
            sourceFrameRate.record(at: time)
            var event = GameFrameTrace.Event("gameInput", sequence: 0, time: time)
            event.captureID = captureID
            event.reason = nativeGPUTime > 0 ? "directAfterGPU" : (nativeRequestTime > 0 ? "directAfterPresented" : "commandBufferBeforePresent")
            frameTrace.record(event)
            if nativeGPUTime > 0 {
                var event = GameFrameTrace.Event("nativeGpuComplete", sequence: 0, time: nativeGPUTime)
                event.captureID = captureID; event.source = nativeRequestTime
                frameTrace.record(event)
            } else if nativeRequestTime > 0 {
                // Direct-present capture begins inside the existing presented
                // callback. Do not register a second callback after presentation,
                // or label our separate copy buffer as the game's rendering GPU.
                var native = GameFrameTrace.Event(nativePresentedTime > 0 ? "nativePresented" : "nativeUnconfirmed",
                                                   sequence: 0, time: nativePresentedTime > 0 ? nativePresentedTime : nativeCallbackTime)
                native.captureID = captureID; native.source = nativeRequestTime
                native.callbackTime = nativeCallbackTime
                frameTrace.record(native)
            } else if frameTrace.isRecording(at: time) {
                let id = captureID
                let nativeTiming = RenderTiming()
                buffer.addCompletedHandler { [self] completed in
                    if completed.status == .completed, completed.gpuEndTime > 0 {
                        nativeTiming.complete(completed.gpuEndTime)
                        var gpu = GameFrameTrace.Event("nativeGpuComplete", sequence: 0, time: completed.gpuEndTime)
                        gpu.captureID = id; gpu.source = time
                        gpu.callbackTime = CACurrentMediaTime()
                        frameTrace.record(gpu)
                    }
                }
                drawable.addPresentedHandler { [self] shown in
                    var event = GameFrameTrace.Event(shown.presentedTime > 0 ? "nativePresented" : "nativeUnconfirmed",
                                                     sequence: 0, time: shown.presentedTime > 0 ? shown.presentedTime : CACurrentMediaTime())
                    event.captureID = id; event.source = time; event.gpu = nativeTiming.read()
                    event.callbackTime = CACurrentMediaTime()
                    frameTrace.record(event)
                }
            }
        }
        // 原来这三种跳过都是静默的，采集率掉了也看不出来。
        if busy { lock.unlock(); trace.count(.captureSkippedBusy); return captureID }
        if originalView { lock.unlock(); trace.count(.captureSkippedPaused); return captureID }
        if let selected = sourceLayer, selected !== layer {
            lock.unlock(); trace.count(.captureSkippedOtherLayer); return captureID
        }
        if nativeRequestTime > 0, nativeRequestTime <= lastAcceptedNativeRequest {
            lock.unlock()
            var event = GameFrameTrace.Event("dropped", sequence: 0, time: CACurrentMediaTime())
            event.captureID = captureID; event.reason = "captureStaleSource"
            frameTrace.record(event)
            return captureID
        }
        if nativeRequestTime > 0 { lastAcceptedNativeRequest = nativeRequestTime }
        sourceLayer = layer
        busy = true
        lock.unlock()
        let texture = drawable.texture
        trace.noteCaptured(time: CACurrentMediaTime(), width: texture.width, height: texture.height)
        // HDR formats need a separate color pipeline. Keep the original game visible.
        guard texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb else {
            fail("暂不支持 HDR 或此纹理格式：\(texture.pixelFormat.rawValue)"); releaseJob(); return captureID
        }
        // One capture job at a time; the RGB→NV12 command completes before
        // releaseJob(), so a single private texture can be reused safely.
        if captureTexture?.width != texture.width || captureTexture?.height != texture.height
            || captureTexture?.pixelFormat != texture.pixelFormat || captureTexture?.device.registryID != texture.device.registryID {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                width: texture.width, height: texture.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            descriptor.storageMode = .private
            captureTexture = layer.device?.makeTexture(descriptor: descriptor)
        }
        guard let copy = captureTexture, let blit = buffer.makeBlitCommandEncoder() else {
            trace.count(.captureNoTexture); releaseJob(); return captureID
        }
        blit.copy(from: texture, to: copy)
        blit.endEncoding()
        // Fixture-only GPU readback verifies that early capture contains the
        // current frame's marker, rather than unrendered or recycled pixels.
        let expectedMarker: Int? = ProcessInfo.processInfo.processName == "GameHookFixture"
            && CommandLine.arguments.contains("--validate-copy")
            ? buffer.label.flatMap { $0.hasPrefix("FixtureFrame:") ? Int($0.dropFirst(13)).map { $0 % 251 } : nil } : nil
        var markerReadback: MTLBuffer?
        if expectedMarker != nil, let result = copy.device.makeBuffer(length: 256, options: .storageModeShared),
           let check = buffer.makeBlitCommandEncoder() {
            check.copy(from: copy, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                       sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: result,
                       destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            check.endEncoding()
            markerReadback = result
        }
        let readback = markerReadback
        let timestamp = CACurrentMediaTime()
        let acceptedCaptureID = captureID
        buffer.addCompletedHandler { [self, drawable] completed in
            _ = drawable // Retain the source drawable until the GPU copy is complete.
            guard completed.status == .completed else {
                trace.count(.captureGpuFailed); releaseJob(); return
            }
            if let expectedMarker, let readback {
                let actual = Int(readback.contents().assumingMemoryBound(to: UInt8.self)[2])
                var validation = GameFrameTrace.Event("captureValidation", sequence: 0, time: CACurrentMediaTime())
                validation.captureID = acceptedCaptureID
                validation.source = Double(expectedMarker); validation.ready = Double(actual)
                validation.reason = abs(actual - expectedMarker) <= 1 ? "pass" : "fail"
                frameTrace.record(validation)
            }
            var event = GameFrameTrace.Event("captureComplete", sequence: 0, time: CACurrentMediaTime())
            event.captureID = acceptedCaptureID
            event.source = timestamp
            event.gpu = completed.gpuEndTime > 0 ? completed.gpuEndTime : nil
            frameTrace.record(event)
            work.async { [self] in process(texture: copy, layer: layer, time: timestamp, captureID: acceptedCaptureID) }
        }
        return captureID
    }

    func recordCaptureFallback(requested: Double, reason: String) {
        var event = GameFrameTrace.Event("captureFallback", sequence: 0, time: CACurrentMediaTime())
        event.source = requested; event.reason = reason
        frameTrace.record(event)
    }

    func recordNativePresentation(captureID: UInt64, requested: Double, presented: Double, callback: Double) {
        var event = GameFrameTrace.Event(presented > 0 ? "nativePresented" : "nativeUnconfirmed",
                                        sequence: 0, time: presented > 0 ? presented : callback)
        event.captureID = captureID; event.source = requested; event.callbackTime = callback
        frameTrace.record(event)
    }

    private func releaseJob() { lock.lock(); busy = false; lock.unlock() }

    /// Main-thread A/B comparison without restarting or changing the game files.
    func toggleOriginalView() {
        comparisonRecorder.stop()
        lock.lock()
        originalView.toggle()
        let paused = originalView
        lock.unlock()
        setOverlayHidden(true, reason: "originalViewToggle")
        lastReadyTime = 0
        interpolationFailed = false
        submissions.reset(keepingSubmissionOrder: true)
        samples.removeAll(keepingCapacity: true)
        processingSamples.removeAll(keepingCapacity: true)
        metricPresentedTimes.removeAll(keepingCapacity: true)
        displayPresentedTimes.removeAll(keepingCapacity: true)
        metricsStart = CACurrentMediaTime()
        lock.lock(); sourceFrameRate.reset(at: metricsStart); lock.unlock()
        displayReportTime = CACurrentMediaTime()
        work.async { [self] in previous = nil; preparedPreviousPlan = nil; playout.reset(); pressure.reset(); multiFrameDelay.reset(); pressureGeneration += 1 }
        displayGraceDeadline = CACurrentMediaTime() + 1
        report(paused ? "PAUSED 已切换到游戏原画面；按 ⌥⇧I 恢复插帧" : "RESUMED 已恢复插帧，等待新画面")
    }

    private func fail(_ message: String) {
        report("ERROR \(message)")
        DispatchQueue.main.async { [self] in
            lastReadyTime = 0
            interpolationFailed = true
            setOverlayHidden(true, reason: "pipelineFailed")
        }
    }

    private func process(texture: MTLTexture, layer: CAMetalLayer, time: Double, captureID: UInt64) {
        // Only the copy/conversion owns capture's busy flag. Apple owns separate
        // NV12 buffers and must not stall the next source frame's capture.
        defer { releaseJob() }
        drainStallReports()
        var submittedJob = false
        do {
            let size = CGSize(width: texture.width, height: texture.height)
            if size != geometry {
                // 几何变化要把整条显示链重建一遍：颜色转换器、缩放器（现场编译 Metal
                // 源码）、VideoToolbox 会话、显示层。全部发生在 capture busy 窗口内，
                // 所以逐段计时，看它是不是"卡住整个画面"的来源。
                let rebuildStart = CACurrentMediaTime()
                let previousSize = geometry
                geometry = size
                previous = nil
                preparedPreviousPlan = nil
                pressure.reset()
                multiFrameDelay.reset()
                pressureGeneration += 1
                epoch += 1
                playout.reset()
                converter = try GameFrameColorConverter(device: texture.device)
                let converterEnd = CACurrentMediaTime()
                renderQueue = texture.device.makeCommandQueue()
                // 代理档位没变就复用已经启动的 VideoToolbox 会话：重建会话要几十毫秒，
                // 而 3024×1898 与 3024×1764 用的是同一个 1080p 代理。
                var reusedSession = false
                if let existing = interpolator {
                    do {
                        try existing.reconfigure(width: texture.width, height: texture.height)
                        reusedSession = true
                    } catch {
                        reusedSession = false
                    }
                }
                if !reusedSession {
                    let testProxy = ProcessInfo.processInfo.processName == "GameHookFixture"
                        ? CommandLine.arguments.first { $0.hasPrefix("--proxy-width=") }.flatMap { Int($0.dropFirst(14)) } : nil
                    let profile = GameInterpolationProfile(rawValue: ProcessInfo.processInfo.environment["SWITCHVIEWER_GAME_PROFILE"] ?? "") ?? .clarity
                    interpolator = try AppleDownsampledFrameInterpolator(width: texture.width, height: texture.height,
                        maximumProxyWidth: testProxy ?? profile.maximumProxyWidth, multiplier: interpolationOptions.multiplier)
                }
                let interpolatorEnd = CACurrentMediaTime()
                if let size = interpolator?.proxySize { report("INTERPOLATION_PROXY width=\(size.width) height=\(size.height)") }
                let revision = epoch
                trace.noteRebuilt(time: rebuildStart,
                                  from: "\(Int(previousSize.width))x\(Int(previousSize.height))",
                                  to: "\(texture.width)x\(texture.height)",
                                  converterMilliseconds: (converterEnd - rebuildStart) * 1_000,
                                  interpolatorMilliseconds: (interpolatorEnd - converterEnd) * 1_000,
                                  overlayMilliseconds: 0)
                DispatchQueue.main.async { [self] in
                    // 主队列重建显示层的耗时单独量：它同时被游戏主线程占着。
                    let overlayStart = CACurrentMediaTime()
                    configureOverlay(source: layer, revision: revision)
                    trace.noteSkipped(time: overlayStart, note: String(
                        format: "overlay %.1fms（含主队列等待）", (CACurrentMediaTime() - overlayStart) * 1_000))
                }
                report(String(format: "READY %d×%d，Apple \(interpolationOptions.multiplier.label) 插帧；显示链重建 conv=%.1fms itp=%.1fms(%@) total=%.1fms",
                              texture.width, texture.height,
                              (converterEnd - rebuildStart) * 1_000,
                              (interpolatorEnd - converterEnd) * 1_000,
                              reusedSession ? "复用会话" : "新建会话",
                              (interpolatorEnd - rebuildStart) * 1_000))
            }
            guard let converter, let interpolator else { fail("无法转换游戏纹理"); return }
            let before = previous
            let beforeTime = previousTime
            let revision = epoch
            let originalReadyTime = CACurrentMediaTime()
            let wasPrepared = preparedPreviousPlan != nil
            let plan = preparedPreviousPlan ?? before.flatMap { _ in playout.plan(previousTime: beforeTime, currentTime: time, readyTime: originalReadyTime) }
            let beforeSequence = previousSequence
            pairSequence += 1
            let sequence = pairSequence * UInt64(interpolationOptions.multiplier.rawValue)
            var inputEvent = GameFrameTrace.Event("input", sequence: sequence, time: time)
            inputEvent.captureID = captureID
            inputEvent.source = time
            frameTrace.record(inputEvent)
            if let plan {
                trace.notePlanned(time: originalReadyTime, sequence: beforeSequence,
                                  deadline: plan.originalDeadline,
                                  expires: plan.nextOriginalDeadline, prequeued: wasPrepared)
            }
            if let before, let plan, !wasPrepared, interpolationOptions.usesLegacyTiming {
                // During cadence warm-up only, the previous NV12 is already complete. Queue it before converting
                // the second frame and before the Apple submit/proxy work starts.
                DispatchQueue.main.async { [self] in
                    guard !originalView, !interpolationFailed, presentationEpoch == revision else { return }
                    lastReadyTime = CACurrentMediaTime()
                    schedule(before, at: plan.originalDeadline, revision: revision, sourceTime: beforeTime,
                             readyTime: originalReadyTime, processing: nil, interval: plan.interval,
                             original: true, sequence: beforeSequence, expires: plan.nextOriginalDeadline)
                }
            }
            let convertStart = CACurrentMediaTime()
            let current = try converter.makeNV12(from: texture)
            trace.noteConverted(time: convertStart,
                                milliseconds: (CACurrentMediaTime() - convertStart) * 1_000)
            comparisonRecorder.append(current, track: .original, hostTime: time)
            previous = current
            previousTime = time
            previousSequence = sequence
            var readyEvent = GameFrameTrace.Event("originalReady", sequence: sequence, time: CACurrentMediaTime())
            readyEvent.captureID = captureID
            readyEvent.source = time
            frameTrace.record(readyEvent)
            let interval = time - beforeTime
            let cadence = before.flatMap { _ in playout.observeInterval(interval) }
            preparedPreviousPlan = before.flatMap { _ in
                // High-rate inputs have little room to hold a future drawable;
                // retain the existing parallel path instead of adding display lag.
                guard let cadence else { return nil }
                let delay: Double
                if interpolationOptions.usesLegacyTiming {
                    guard GameFramePlayoutPlanner.supportsPrequeue(interval: cadence),
                          let legacyDelay = pressure.delay(interval: cadence) else { return nil }
                    delay = legacyDelay
                } else { delay = multiFrameDelay.delay(interval: cadence, options: interpolationOptions) }
                let now = CACurrentMediaTime()
                if now - lastPressureReport >= 1 {
                    lastPressureReport = now
                    report(String(format: "ADAPT elapsed=%.2f delayMs=%.2f processingBudgetMs=%.2f midpointDeliveryRate=%.3f", now - startedAt, delay * 1000, pressure.processingBudget * 1000, pressure.deliveryRate ?? .nan))
                }
                return playout.prepareOriginal(sourceTime: time, interval: cadence, readyTime: now,
                                               adaptiveDelay: delay, allowShortDelay: !interpolationOptions.usesLegacyTiming)
            }
            if let prepared = preparedPreviousPlan {
                let ready = CACurrentMediaTime()
                DispatchQueue.main.async { [self] in
                    guard !originalView, !interpolationFailed, presentationEpoch == revision else { return }
                    lastReadyTime = CACurrentMediaTime()
                    schedule(current, at: prepared.originalDeadline, revision: revision, sourceTime: time,
                             readyTime: ready, processing: nil, interval: interval,
                             original: true, sequence: sequence, expires: prepared.nextOriginalDeadline, prequeued: true, cadenceInterval: prepared.interval)
                }
            }
            guard let before, let plan else { return }
            if interpolationOptions.delayBudgetMilliseconds == 0 {
                DispatchQueue.main.async { [self] in phaseDropped += interpolationOptions.multiplier.rawValue - 1 }
                return
            }
            guard !interpolationBusy else {
                if !interpolationOptions.usesLegacyTiming {
                    DispatchQueue.main.async { [self] in phaseDropped += interpolationOptions.multiplier.rawValue - 1 }
                }
                trace.count(.interpolateSkippedBusy)
                var event = GameFrameTrace.Event("dropped", sequence: beforeSequence + 1, time: CACurrentMediaTime())
                event.reason = "interpolateSkippedBusy"
                frameTrace.record(event)
                return
            }
            interpolationBusy = true
            submittedJob = true
            trace.count(.interpolateSubmitted)
            if !interpolationOptions.usesLegacyTiming {
                try submitPhaseGroup(interpolator: interpolator, previous: before, current: current,
                    beforeTime: beforeTime, currentTime: time, originalReadyTime: originalReadyTime,
                    beforeSequence: beforeSequence, plan: plan, revision: revision, prequeued: wasPrepared)
                return
            }
            DispatchQueue.main.async { [self] in
                guard presentationEpoch == revision else { return }
                submissions.policy.beginMidpoint(beforeSequence + 1)
            }
            try interpolator.submit(previous: before, current: current,
                previousPresentationTimeStamp: CMTime(seconds: beforeTime, preferredTimescale: 1_000_000),
                currentPresentationTimeStamp: CMTime(seconds: time, preferredTimescale: 1_000_000)) { [self] result, error in
                // Fixture-only fault injection exercises feedback without changing
                // a real game's processing or display path.
                let elapsed = CACurrentMediaTime() - startedAt
                let pressureTest = ProcessInfo.processInfo.processName == "GameHookFixture"
                    && CommandLine.arguments.contains("--pressure-test")
                let delay = pressureTest && elapsed >= 4 && elapsed < 8 ? 0.015 : 0
                work.asyncAfter(deadline: .now() + delay) { [self] in
                    interpolationBusy = false
                    guard epoch == revision else { return }
                    lock.lock()
                    let paused = originalView
                    lock.unlock()
                    guard !paused else { return }
                    guard let result else {
                        trace.count(.interpolateFailed)
                        report("ERROR \(error?.localizedDescription ?? "Apple 插帧无输出")")
                        DispatchQueue.main.async { [self] in
                            clearPendingMidpoint(beforeSequence + 1)
                            setOverlayHidden(true, reason: "interpolationFailed"); lastReadyTime = 0; interpolationFailed = true
                        }
                        return
                    }
                    trace.count(.interpolateCompleted)
                    generated += 1
                    let now = CACurrentMediaTime()
                    // Include current-frame conversion, proxy setup and callback delivery,
                    // not just the duration reported by the Apple algorithm.
                    let duration = max(result.processingMilliseconds / 1000, now - originalReadyTime)
                    var generatedEvent = GameFrameTrace.Event("midpointReady", sequence: beforeSequence + 1, time: now)
                    generatedEvent.source = beforeTime
                    generatedEvent.currentSource = time
                    generatedEvent.ready = originalReadyTime
                    generatedEvent.processing = duration
                    generatedEvent.algorithm = result.processingMilliseconds / 1000
                    frameTrace.record(generatedEvent)
                    pressure.recordProcessing(seconds: duration)
                    let generation = pressureGeneration
                    let feedback = DeliveryFeedback { [self] shown in
                        work.async { [self] in
                            guard epoch == revision, pressureGeneration == generation else { return }
                            pressure.recordDelivery(shown: shown)
                        }
                    }
                    let interval = time - beforeTime
                    DispatchQueue.main.async { [self] in
                        guard !originalView, presentationEpoch == revision else { feedback.finish(false); return }
                        interpolationFailed = false
                        // Include completed jobs even if their midpoint misses the slot;
                        // otherwise the processing chart would hide the slow jobs.
                        processingSamples.append(result.processingMilliseconds)
                        if processingSamples.count > 120 { processingSamples.removeFirst(processingSamples.count - 120) }
                        // A late result may use the remainder of its own slot, but
                        // must never overwrite a newer original or extend the timeline.
                        guard plan.midpointIsUseful(at: CACurrentMediaTime()) else {
                            trace.count(.midpointDroppedNotUseful)
                            clearPendingMidpoint(beforeSequence + 1)
                            var event = GameFrameTrace.Event("dropped", sequence: beforeSequence + 1, time: CACurrentMediaTime())
                            event.reason = "midpointDroppedNotUseful"
                            event.expires = plan.nextOriginalDeadline
                            frameTrace.record(event)
                            feedback.finish(false); return
                        }
                        lastReadyTime = CACurrentMediaTime()
                        schedule(result.pixelBuffer, at: plan.midpointDeadline, revision: revision, sourceTime: beforeTime,
                                 readyTime: now, processing: result.processingMilliseconds, interval: interval,
                                 original: false, sequence: beforeSequence + 1, expires: plan.nextOriginalDeadline, prequeued: wasPrepared, cadenceInterval: plan.interval, feedback: feedback)
                    }
                    if now - lastReport > 2 {
                        lastReport = now
                        report("ACTIVE generated=\(generated) sourceIntervalMs=\(Int(interval * 1000)) processingMs=\(Int(result.processingMilliseconds))")
                    }
                }
            }
        } catch {
            // 覆盖 makeNV12 与 interpolator.submit 两条失败路径。
            trace.count(.convertFailed)
            if submittedJob { interpolationBusy = false }
            fail(error.localizedDescription)
        }
    }

    private func submitPhaseGroup(interpolator: AppleDownsampledFrameInterpolator,
                                  previous: CVPixelBuffer, current: CVPixelBuffer,
                                  beforeTime: Double, currentTime: Double, originalReadyTime: Double,
                                  beforeSequence: UInt64, plan: GameFramePlayoutPlanner.Plan,
                                  revision: Int, prequeued: Bool) throws {
        let interval = plan.interval
        let sourceInterval = currentTime - beforeTime
        let factor = interpolationOptions.multiplier.rawValue
        let slotInterval = interval / Double(factor)
        try interpolator.submitFrames(previous: previous, current: current,
            previousPresentationTimeStamp: CMTime(seconds: beforeTime, preferredTimescale: 1_000_000),
            currentPresentationTimeStamp: CMTime(seconds: currentTime, preferredTimescale: 1_000_000),
            onFrame: { [self] buffer, phase, processingMS in
                let ready = CACurrentMediaTime()
                work.async { [self] in
                    guard epoch == revision else { return }
                    multiFrameDelay.record(phase: phase, interval: sourceInterval, readySeconds: max(0, ready - currentTime))
                    generated += 1
                    let index = Int((phase * Double(factor)).rounded())
                    let sequence = beforeSequence + UInt64(index)
                    let target = plan.originalDeadline + phase * interval
                    let expires = min(plan.nextOriginalDeadline, target + slotInterval)
                    var event = GameFrameTrace.Event("phaseReady", sequence: sequence, time: ready)
                    event.original = false; event.multiplier = factor; event.phase = phase
                    event.source = beforeTime; event.currentSource = currentTime
                    event.deadline = target; event.expires = expires; event.processing = processingMS / 1000
                    frameTrace.record(event)
                    DispatchQueue.main.async { [self] in
                        guard !originalView, !interpolationFailed, presentationEpoch == revision else { return }
                        guard CACurrentMediaTime() < expires else {
                            phaseDropped += 1
                            trace.count(.midpointDroppedNotUseful)
                            return
                        }
                        let feedback = DeliveryFeedback { [self] shown in
                            DispatchQueue.main.async { [self] in
                                guard presentationEpoch == revision else { return }
                                if shown { phaseShown += 1 } else { phaseDropped += 1 }
                            }
                        }
                        lastReadyTime = CACurrentMediaTime()
                        schedule(buffer, at: target, revision: revision, sourceTime: beforeTime,
                            readyTime: ready, processing: processingMS, interval: sourceInterval,
                            original: false, sequence: sequence, expires: expires, prequeued: prequeued,
                            cadenceInterval: interval, feedback: feedback, interpolationPhase: phase)
                    }
                }
            }, completion: { [self] result, error in
                work.async { [self] in
                    interpolationBusy = false
                    guard epoch == revision else { return }
                    if let error { trace.count(.interpolateFailed); fail(error.localizedDescription); return }
                    trace.count(.interpolateCompleted)
                    if let result {
                        DispatchQueue.main.async { [self] in
                            guard presentationEpoch == revision else { return }
                            processingSamples.append(result.processingMilliseconds)
                            if processingSamples.count > 120 { processingSamples.removeFirst(processingSamples.count - 120) }
                        }
                    }
                    if CACurrentMediaTime() - lastReport > 2 {
                        lastReport = CACurrentMediaTime()
                        report("ACTIVE multiplier=\(factor) generated=\(generated) processingMs=\(Int(result?.processingMilliseconds ?? 0))")
                    }
                }
            })
    }

    private func configureOverlay(source: CAMetalLayer, revision: Int) {
        // 复用同一个 CAMetalLayer。重建 layer 有两个代价：在途 drawable 永远拿不到
        // 呈现回调（TRACE 的 pending 只增不减），新 layer 的首批呈现又常常返回
        // presentedTime=0。几何变化只需要更新尺寸，schedule() 每帧本来就会刷新
        // frame/drawableSize/colorspace，所以这里没有必须重建的理由。
        let output: CAMetalLayer
        if let existing = overlay, existing.device === source.device {
            output = existing
        } else {
            overlay?.removeFromSuperlayer()
            let created = CAMetalLayer()
            created.name = "SwitchViewer.Interpolation"
            created.device = source.device
            created.pixelFormat = .bgra8Unorm
            created.framebufferOnly = false
            created.maximumDrawableCount = 2
            let fixtureUnsynced = ProcessInfo.processInfo.processName == "GameHookFixture"
                && CommandLine.arguments.contains("--unsynced-output")
            created.displaySyncEnabled = !fixtureUnsynced
                && ProcessInfo.processInfo.environment["SWITCHVIEWER_GAME_DISPLAY_SYNC"] != "0"
            created.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
            created.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            output = created
        }
        // Preserve the game's composition behavior, including nil (unmanaged).
        // Labelling an unmanaged/P3 game as sRGB changes saturation on wide-gamut displays.
        output.colorspace = source.colorspace
        output.frame = source.bounds
        output.drawableSize = source.drawableSize
        // 游戏重建 layer 层级时要把自己重新挂回最上层。
        if fixtureRootOutput { NSApp.windows.first(where: { $0.title.hasPrefix("SwitchViewer 游戏内插帧测试") })?.contentView?.layer = output }
        else if output.superlayer !== source { source.addSublayer(output) }
        report("PRESENT_PATH opaque=\(output.isOpaque) drawables=\(output.maximumDrawableCount) transaction=\(output.presentsWithTransaction) sync=\(output.displaySyncEnabled)")
        overlay = output
        presentationEpoch = revision
        submissions.reset()
        pendingPresentation.removeAll(); pendingGPU.removeAll()
        interpolationFailed = false
        samples.removeAll(keepingCapacity: true)
        processingSamples.removeAll(keepingCapacity: true)
        metricPresentedTimes.removeAll(keepingCapacity: true)
        displayPresentedTimes.removeAll(keepingCapacity: true)
        metricsStart = CACurrentMediaTime()
        lock.lock(); sourceFrameRate.reset(at: metricsStart); lock.unlock()
        retryDisplayAfter = 0
        displayGraceDeadline = CACurrentMediaTime() + 1
        displayReportTime = CACurrentMediaTime()
        report("COLOR sourceSpace=\(source.colorspace?.name as String? ?? "unmanaged") encodedRGBPassthrough=true")
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            drainStallReports()
            reportTraceWindow()
            recordDisplayState()
            if originalView { return }
            let now = CACurrentMediaTime()
            // 显示路径彻底不提交时，"两次上屏之间的间隔"永远算不出来，
            // 靠这条探针在长时间静默时倒带。
            trace.probe(time: now)
            if now - lastReadyTime > 0.5 {
                if overlay?.isHidden == false {
                    trace.noteHidden(time: now, reason: .hiddenStaleReady)
                }
                setOverlayHidden(true, reason: "staleReady")
            }
            if lastReadyTime > 0, now > displayGraceDeadline {
                if overlay?.isHidden == false {
                    trace.noteHidden(time: now, reason: .hiddenNoDisplay)
                }
                setOverlayHidden(true, reason: "noPresentation")
                retryDisplayAfter = now + 0.75
                displayGraceDeadline = retryDisplayAfter + 1
                report("ERROR 暂未确认新画面上屏，已恢复游戏原画面并等待重试")
            }
        }
    }

    /// 停顿倒带：卡顿发生时把前后的逐帧事件直接落日志，而不是只留聚合值。
    private func drainStallReports() {
        for stall in trace.takeStallReports() {
            report(String(format: "LAG kind=%@ gap=%.1fms 倒带 %d 条逐帧事件（旧→新）",
                          stall.kind, stall.gapMilliseconds, stall.lines.count))
            for line in stall.lines { report("  " + line) }
        }
    }

    /// 每秒一条窗口行。它不依赖上屏回调，所以显示路径整体挂掉时日志不会静默——
    /// 之前 4 分钟爆发里只剩 ERROR 就是这个盲区。
    private func reportTraceWindow() {
        let now = CACurrentMediaTime()
        guard now - lastTraceReport >= 1 else { return }
        let elapsed = now - lastTraceReport
        lastTraceReport = now
        let window = trace.takeWindow()
        var line = String(format: "TRACE window=%.2fs sched=%d submit=%d present=%d pending=%d",
                          elapsed, window.scheduleAttempts, window.submissions,
                          window.presentations, window.pendingSubmissions)
        if window.captureGapCount > 0 || window.captureGapMaxMilliseconds > 1 {
            line += String(format: " capGapMax=%.1fms capGaps=%d",
                           window.captureGapMaxMilliseconds, window.captureGapCount)
        }
        line += String(format: " gapMax=%.1fms gaps=%d ageMax=%.1fms tgtErrMax=%.1fms s2pMax=%.1fms",
                       window.presentationGapMaxMilliseconds, window.presentationGapCount,
                       window.contentAgeMaxMilliseconds, window.targetErrorMaxMilliseconds,
                       window.submitToPresentMaxMilliseconds)
        if !window.counters.isEmpty {
            line += " | " + window.counters.map { "\($0.label)=\($0.count)" }.joined(separator: " ")
        }
        report(line)
        if !interpolationOptions.usesLegacyTiming {
            let factor = interpolationOptions.multiplier.label
            report("INTERPOLATION_STATUS 目标 \(factor) · 已显示 \(phaseShown) 张插值帧，未显示 \(phaseDropped) 张。" +
                (phaseDropped > 0 ? "可增加预算或降低倍率。" : ""))
            phaseShown = 0; phaseDropped = 0
        }
    }

    private func schedule(_ frame: CVPixelBuffer, at deadline: Double, revision: Int,
                          sourceTime: Double, readyTime: Double, processing: Double?,
                          interval: Double, original: Bool, sequence: UInt64, expires: Double, prequeued: Bool = false, cadenceInterval: Double? = nil, feedback: DeliveryFeedback? = nil, interpolationPhase: Double = 0.5) {
        // Submit before the intended display time: drawable acquisition and GPU
        // work overlap the next input, rather than beginning at its arrival.
        var options = hookConfiguration.presentationOptions(syncEnabled: overlay?.displaySyncEnabled)
        if !interpolationOptions.usesLegacyTiming {
            options.phaseSlots = true
            options.advanceOriginals = false
            options.correctCadence = false
            options.immediate = false
            options.minimumCadenceGap = false
        }
        let submissionGeneration = submissions.generation
        let plan = submissions.policy.plan(sequence: sequence, original: original, target: deadline,
            expires: expires, interval: interpolationOptions.usesLegacyTiming ? (cadenceInterval ?? interval) : (cadenceInterval ?? interval) / Double(interpolationOptions.multiplier.rawValue), prequeued: prequeued, options: options)
        let immediateOutput = options.immediate
        let adaptiveAdmission = options.adaptiveAdmission
        let lead = plan.lead
        let early = plan.advance
        let phaseDelay = plan.phaseDelay
        var scheduledEvent = GameFrameTrace.Event("scheduled", sequence: sequence, time: CACurrentMediaTime())
        if !interpolationOptions.usesLegacyTiming {
            scheduledEvent.original = original; scheduledEvent.multiplier = interpolationOptions.multiplier.rawValue
            scheduledEvent.phase = original ? 0 : interpolationPhase
        }
        scheduledEvent.source = sourceTime
        scheduledEvent.ready = readyTime
        scheduledEvent.deadline = deadline
        scheduledEvent.expires = expires
        scheduledEvent.submissionAdvance = early
        scheduledEvent.pacingDelay = phaseDelay
        frameTrace.record(scheduledEvent)
        let submit: () -> Void = { [self] in
            // 原来的大 guard 分不清是哪一条挡下的；逐条拆开并计数，
            // 这样"没提交上去"的原因可以直接在 DROPS 行里看到。
            let now = CACurrentMediaTime()
            let reserve: () -> Double = { [self] in
                submissions.policy.midpointReserve(plan, framesAhead: pendingPresentation.count)
            }
            var midpointReserve = reserve()
            trace.count(.scheduleAttempt)
            let abandon: (FrameStallTrace.Counter) -> Void = { reason in
                var event = GameFrameTrace.Event("dropped", sequence: sequence, time: CACurrentMediaTime())
                if !original { self.clearPendingMidpoint(sequence) }
                event.reason = reason.label
                event.submissionReserve = original ? lead : midpointReserve
                event.deadline = deadline
                event.expires = expires
                event.pendingPresentation = self.pendingPresentation.count
                event.pendingGPU = self.pendingGPU.count
                event.pendingAcquisition = self.pendingAcquisition
                self.frameTrace.record(event)
                self.trace.noteDropped(time: CACurrentMediaTime(), sequence: sequence, reason: reason,
                                       deadline: deadline, expires: expires)
                feedback?.finish(false)
            }
            let context = GameFramePresentationPolicy.Context(active: !originalView && !interpolationFailed,
                generationMatches: presentationEpoch == revision && submissions.generation == submissionGeneration,
                outputReady: lastReadyTime > 0,
                retryAfter: retryDisplayAfter, framesAhead: pendingPresentation.count)
            if let reason = submissions.policy.initialRejection(plan, at: now, context: context) {
                abandon(reason); return
            }
            guard let overlay, let sourceLayer, let converter, let renderQueue else {
                abandon(.dropMissingResource); return
            }
            // Some engines rebuild their layer hierarchy when leaving fullscreen.
            if !fixtureRootOutput, overlay.superlayer !== sourceLayer { sourceLayer.addSublayer(overlay) }
            // Backpressure is not a visibility failure. Keep the layer visible
            // while outstanding acquisition/presentation work drains; hiding it
            // here can starve nextDrawable until its one-second timeout.
            guard let lease = drawablePool.reserve() else {
                abandon(.dropNoSlot); return
            }
            // 先取消隐藏再取 drawable。层被隐藏时 nextDrawable 有可能一直拿不到
            // drawable，而旧代码只在 commit 成功之后才取消隐藏 —— 于是一旦被看门狗
            // 隐藏，就再也走不到取消隐藏那一行，只能等几何变化重建 layer 才能脱身。
            // 取不到就立刻恢复隐藏，不让旧画面留在屏幕上。
            if overlay.isHidden {
                trace.noteShown(time: now, sequence: sequence)
                setOverlayHidden(false, reason: "acquireDrawable", sequence: sequence)
            }
            if overlay.frame != sourceLayer.bounds { overlay.frame = sourceLayer.bounds }
            if overlay.drawableSize != sourceLayer.drawableSize { overlay.drawableSize = sourceLayer.drawableSize }
            if overlay.colorspace !== sourceLayer.colorspace { overlay.colorspace = sourceLayer.colorspace }
            drawablePool.acquire(overlay, sequence: sequence, expires: expires) { [self] drawable, drawableWait in
                // Acquisition can outlive this frame's slot or even a layer rebuild.
                // Keep all state, sequence decisions and commits on the main queue.
                let reject: (FrameStallTrace.Counter) -> Void = { reason in
                    lease.release()
                    abandon(reason)
                }
                let context = GameFramePresentationPolicy.Context(active: !originalView && !interpolationFailed,
                    generationMatches: presentationEpoch == revision && submissions.generation == submissionGeneration,
                    outputReady: lastReadyTime > 0,
                    retryAfter: retryDisplayAfter, framesAhead: pendingPresentation.count)
                if context.active && context.generationMatches {
                    // Include queue and return-to-main time, including acquisitions
                    // later rejected by pair ownership; avoid success-only bias.
                    submissions.policy.recordAcquisition(seconds: CACurrentMediaTime() - now)
                }
                if let reason = submissions.policy.acquisitionRejection(plan, at: CACurrentMediaTime(), context: context) {
                    reject(reason); return
                }
                guard let drawable else {
                    setOverlayHidden(true, reason: "noDrawable", sequence: sequence)
                    lease.release(); abandon(.dropNoDrawable); return
                }
                guard let command = renderQueue.makeCommandBuffer() else {
                    setOverlayHidden(true, reason: "noCommandBuffer", sequence: sequence)
                    lease.release(); abandon(.dropNoCommandBuffer); return
                }
                command.label = "SwitchViewerOutput:\(sequence):\(original ? "original" : "midpoint")"
                SVTagOverlayDrawable(Unmanaged.passUnretained(drawable as AnyObject).toOpaque(), sequence)
                let renderTiming = RenderTiming()
                let encodeStart = CACurrentMediaTime()
                do { try converter.encodeRGB(from: frame, to: drawable.texture, command: command) }
                catch {
                    lease.release()
                    if !original { clearPendingMidpoint(sequence) }
                    trace.noteDropped(time: CACurrentMediaTime(), sequence: sequence,
                                      reason: .dropEncodeFailed, deadline: deadline, expires: expires)
                    feedback?.finish(false)
                    setOverlayHidden(true, reason: "encodeFailed", sequence: sequence)
                    report("ERROR \(error.localizedDescription)")
                    return
                }
                let encodeMilliseconds = (CACurrentMediaTime() - encodeStart) * 1000
                submissions.policy.recordEncoding(seconds: encodeMilliseconds / 1000)
                let submitTime = CACurrentMediaTime()
                let requestedTime = submissions.policy.requestTime(plan, submittedAt: submitTime)
                // Queue pressure can change while nextDrawable is being acquired.
                midpointReserve = submissions.policy.midpointReserve(plan, framesAhead: pendingPresentation.count, prepared: true)
                let framesAhead = pendingPresentation.count
                if let reason = submissions.policy.finalRejection(plan, at: submitTime, framesAhead: framesAhead, prepared: true) {
                    lease.release(); abandon(reason); return
                }
                let minimumDuration = submissions.policy.minimumDuration(plan, at: submitTime, interval: cadenceInterval ?? interval)
                submissions.policy.submitted(sequence)
                if !original { clearPendingMidpoint(sequence) }
                pendingPresentation.insert(sequence); pendingGPU.insert(sequence)
                var submittedEvent = GameFrameTrace.Event("submitted", sequence: sequence, time: submitTime)
                submittedEvent.pendingPresentation = pendingPresentation.count
                submittedEvent.pendingGPU = pendingGPU.count
                submittedEvent.pendingAcquisition = pendingAcquisition
                submittedEvent.reason = options.preparationAdmission && immediateOutput ? "unsyncedPreparedPair" :
                    (adaptiveAdmission ? "unsyncedAdaptive" : (immediateOutput ? "unsyncedImmediate" : "timedCalibration"))
                if minimumDuration > 0 { submittedEvent.minimumDuration = minimumDuration }
                submittedEvent.drawableID = UInt64(drawable.drawableID)
                if !interpolationOptions.usesLegacyTiming {
                    submittedEvent.original = original; submittedEvent.multiplier = interpolationOptions.multiplier.rawValue
                    submittedEvent.phase = original ? 0 : interpolationPhase
                }
                submittedEvent.source = sourceTime
                submittedEvent.requested = requestedTime
                submittedEvent.deadline = deadline
                submittedEvent.expires = expires
                submittedEvent.submissionReserve = original ? lead : midpointReserve
                submittedEvent.submissionAdvance = early
                submittedEvent.pacingDelay = phaseDelay
                frameTrace.record(submittedEvent)
                trace.noteSubmitted(time: submitTime, sequence: sequence, deadline: deadline, expires: expires,
                                    drawableWaitMilliseconds: drawableWait,
                                    encodeMilliseconds: encodeMilliseconds)
                let recordingAspect = Double(overlay.drawableSize.width / overlay.drawableSize.height)
                drawable.addPresentedHandler { [self] presented in
                    defer {
                        DispatchQueue.main.async { [self] in
                            guard presentationEpoch == revision else { return }
                            pendingPresentation.remove(sequence)
                        }
                    }
                    guard presented.presentedTime > 0 else {
                        frameTrace.record(.init("unconfirmed", sequence: sequence, time: CACurrentMediaTime()))
                        // 提交成功但系统没确认上屏：这条以前是完全静默的。
                        trace.noteUnconfirmed(time: CACurrentMediaTime(), sequence: sequence,
                                              submitTime: submitTime)
                        feedback?.finish(false); return
                    }
                    comparisonRecorder.append(frame, track: .processed,
                        hostTime: sourceTime + (original ? 0 : interval * interpolationPhase), generated: !original,
                        referenceAspect: recordingAspect)
                    trace.notePresented(time: presented.presentedTime, sequence: sequence,
                                        sourceTime: sourceTime, submitTime: submitTime, deadline: deadline,
                                        drawableWaitMilliseconds: drawableWait,
                                        encodeMilliseconds: encodeMilliseconds)
                    var presentedEvent = GameFrameTrace.Event("presented", sequence: sequence, time: presented.presentedTime)
                    presentedEvent.drawableID = UInt64(presented.drawableID)
                    presentedEvent.callbackTime = CACurrentMediaTime()
                    if !interpolationOptions.usesLegacyTiming {
                        presentedEvent.original = original; presentedEvent.multiplier = interpolationOptions.multiplier.rawValue
                        presentedEvent.phase = original ? 0 : interpolationPhase
                    }
                    presentedEvent.source = sourceTime
                    presentedEvent.ready = readyTime
                    presentedEvent.deadline = deadline
                    presentedEvent.requested = requestedTime
                    presentedEvent.gpu = renderTiming.read()
                    frameTrace.record(presentedEvent)
                    feedback?.finish(true)
                    DispatchQueue.main.async { [self] in
                        guard !originalView, presentationEpoch == revision,
                              submissions.generation == submissionGeneration else { return }
                        submissions.policy.presented(plan, submittedAt: submitTime, requestedAt: requestedTime,
                            presentedAt: presented.presentedTime, framesAhead: framesAhead)
                        displayGraceDeadline = CACurrentMediaTime() + 1
                        retryDisplayAfter = 0
                        let hostTick = Int64((presented.presentedTime * 1_000_000).rounded())
                        displayPresentedTimes.insert(hostTick)
                        let uniqueMetric = metricPresentedTimes.insert(hostTick).inserted
                        let age = (presented.presentedTime - sourceTime) * 1000
                        let wait = (presented.presentedTime - readyTime) * 1000
                        if uniqueMetric, age.isFinite, age >= 0, wait.isFinite, wait >= 0 {
                            samples.append(DisplaySample(age: age, readyWait: wait, processing: processing,
                                                         interval: interval * 1000, original: original, presentedTime: presented.presentedTime, sequence: sequence, submitAge: (submitTime - sourceTime) * 1000,
                                                         targetError: (presented.presentedTime - deadline) * 1000, drawableWait: drawableWait,
                                                         gpu: renderTiming.read().map { max(0, ($0 - submitTime) * 1000) },
                                                         compositor: renderTiming.read().map { max(0, (presented.presentedTime - $0) * 1000) }))
                            if samples.count > 600 { samples.removeFirst(samples.count - 600) }
                        }
                        let metricsElapsed = CACurrentMediaTime() - metricsStart
                        if metricsElapsed >= 1, !samples.isEmpty {
                            func percentile(_ values: [Double], _ fraction: Double) -> Double {
                                guard !values.isEmpty else { return .nan }
                                let sorted = values.sorted()
                                return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
                            }
                            lock.lock()
                            let sourceFPS = sourceFrameRate.sample(at: CACurrentMediaTime()) ?? .nan
                            lock.unlock()
                            let ordered = samples.sorted { $0.presentedTime < $1.presentedTime }
                            let orderErrors = zip(ordered, ordered.dropFirst()).filter { $0.0.sequence >= $0.1.sequence }.count
                            // Keep the headline tied to originals. Midpoint reference age
                            // includes its half-frame offset and is a separate diagnostic.
                            let originals = samples.filter { $0.original }.map(\.age)
                            let midpoints = samples.filter { !$0.original }.map(\.age)
                            report(String(format: "METRICS fps=%.1f latencyP50=%.2f latencyP95=%.2f processingP50=%.2f readyToDisplayP50=%.2f sourceIntervalP50=%.2f originalAgeP50=%.2f midpointReferenceAgeP50=%.2f nextDrawableP50=%.2f submitToGPUCompleteP50=%.2f gpuCompleteToDisplayP50=%.2f originalSubmitAgeP50=%.2f targetErrorP50=%.2f presentationOrderErrors=%d originalSamples=%d midpointSamples=%d gpuSamples=%d processingJobs=%d samples=%d sourceFPS=%.2f",
                                Double(samples.count) / metricsElapsed, percentile(originals, 0.5),
                                percentile(originals, 0.95), percentile(processingSamples, 0.5),
                                percentile(samples.map(\.readyWait), 0.5), percentile(samples.map(\.interval), 0.5),
                                percentile(originals, 0.5), percentile(midpoints, 0.5),
                                percentile(samples.map(\.drawableWait), 0.5), percentile(samples.compactMap(\.gpu), 0.5),
                                percentile(samples.compactMap(\.compositor), 0.5),
                                percentile(samples.filter { $0.original }.map(\.submitAge), 0.5), percentile(samples.map(\.targetError), 0.5), orderErrors, originals.count, midpoints.count, samples.compactMap(\.gpu).count, processingSamples.count, samples.count, sourceFPS)
                                + String(format: " presentationAdvanceMs=%.2f originalPresentationAdvanceMs=%.2f allReferenceAgeP50=%.2f allReferenceAgeP95=%.2f", submissions.policy.presentationAdvance * 1000, submissions.policy.originalPresentationAdvance * 1000,
                                         percentile(samples.map(\.age), 0.5), percentile(samples.map(\.age), 0.95)))
                            samples.removeAll(keepingCapacity: true)
                            processingSamples.removeAll(keepingCapacity: true)
                            metricPresentedTimes.removeAll(keepingCapacity: true)
                            metricsStart = CACurrentMediaTime()
                        }
                        let elapsed = CACurrentMediaTime() - displayReportTime
                        if elapsed > 2 {
                            report("DISPLAY outputFPS=\(Int(Double(displayPresentedTimes.count) / elapsed))")
                            displayReportTime = CACurrentMediaTime()
                            displayPresentedTimes.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if frameTrace.isRecording(at: CACurrentMediaTime()) {
                    command.addScheduledHandler { [self] _ in
                        frameTrace.record(.init("gpuScheduledCallback", sequence: sequence, time: CACurrentMediaTime()))
                    }
                }
                command.addCompletedHandler { [self] completed in
                    DispatchQueue.main.async { [self] in
                        guard presentationEpoch == revision else { return }
                        pendingGPU.remove(sequence)
                    }
                    // GPU host timestamps avoid completion-callback delivery delay.
                    if completed.status == .completed, completed.gpuEndTime > 0 {
                        renderTiming.complete(completed.gpuEndTime)
                        if completed.gpuStartTime > 0 {
                            frameTrace.record(.init("gpuStart", sequence: sequence, time: completed.gpuStartTime))
                        }
                        var event = GameFrameTrace.Event("gpuComplete", sequence: sequence, time: completed.gpuEndTime)
                        event.callbackTime = CACurrentMediaTime()
                        frameTrace.record(event)
                    }
                    else if completed.status != .completed { feedback?.finish(false) }
                    lease.release()
                }
                if minimumDuration > 0 { command.present(drawable, afterMinimumDuration: minimumDuration) }
                else if prequeued && requestedTime > submitTime + 0.001 { command.present(drawable, atTime: requestedTime) }
                else { command.present(drawable) }
                frameTrace.record(.init("commandCommitBegin", sequence: sequence, time: CACurrentMediaTime()))
                command.commit()
                frameTrace.record(.init("commandCommitEnd", sequence: sequence, time: CACurrentMediaTime()))
            }
        }
        submissions.enqueue(plan, submit: submit) { [self] hold in
            var event = GameFrameTrace.Event("originalSubmissionHeld", sequence: hold.sequence, time: hold.time)
            event.deadline = hold.nominal
            event.expires = hold.until
            frameTrace.record(event)
        }
    }

    private func clearPendingMidpoint(_ sequence: UInt64) { submissions.resolveMidpoint(sequence) }

    private var fixtureRootOutput: Bool {
        ProcessInfo.processInfo.processName == "GameHookFixture"
            && CommandLine.arguments.contains("--root-output")
            && CommandLine.arguments.contains("--offscreen-producer")
    }

    private func setOverlayHidden(_ hidden: Bool, reason: String, sequence: UInt64 = 0) {
        guard let overlay, overlay.isHidden != hidden else { return }
        overlay.isHidden = hidden
        var event = GameFrameTrace.Event("overlayVisibility", sequence: sequence, time: CACurrentMediaTime())
        event.overlayHidden = hidden; event.reason = reason
        event.pendingPresentation = pendingPresentation.count
        event.pendingGPU = pendingGPU.count
        event.pendingAcquisition = pendingAcquisition
        frameTrace.record(event)
    }

    /// Visibility and pending callbacks are sampled on main, never on the render queue.
    private func recordDisplayState() {
        let now = CACurrentMediaTime()
        guard frameTrace.isRecording(at: now) else { return }
        var layer: CALayer? = sourceLayer
        var window: NSWindow?
        while let current = layer {
            if let view = current.delegate as? NSView, let host = view.window { window = host; break }
            layer = current.superlayer
        }
        if window == nil, fixtureRootOutput {
            window = NSApp.windows.first(where: { $0.title.hasPrefix("SwitchViewer 游戏内插帧测试") })
        }
        var event = GameFrameTrace.Event("displayState", sequence: 0, time: now)
        if let display = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            event.displayID = display.uint32Value
            presentationObserver.observe(display: display.uint32Value, trace: frameTrace)
        }
        event.windowFullscreen = window?.styleMask.contains(.fullScreen)
        event.surfaceWidth = overlay.map { Int($0.drawableSize.width) }
        event.surfaceHeight = overlay.map { Int($0.drawableSize.height) }
        event.screenMaximumFPS = window?.screen?.maximumFramesPerSecond
        event.syncEnabled = overlay?.displaySyncEnabled
        event.overlayHidden = overlay?.isHidden
        event.windowVisible = window?.isVisible
        event.windowOccluded = window.map { !$0.occlusionState.contains(.visible) }
        event.applicationActive = NSApp.isActive
        event.pendingPresentation = pendingPresentation.count
        event.pendingGPU = pendingGPU.count
        event.pendingAcquisition = pendingAcquisition
        frameTrace.record(event)
    }
}
