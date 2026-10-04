import CoreMedia
import CoreVideo
import QuartzCore
import VideoToolbox

struct PreviewFrame {
    let buffer: CVPixelBuffer
    let sourceAspect: Double
    let receivedAt: Double
    let interpolated: Bool
}

/// All processing state is owned by the capture frame queue. Presentation is locked separately.
final class FramePipeline {
    let frames = TimedFrameQueue<PreviewFrame>()
    var report: ((Double, Double?, String) -> Void)?
    private var previous: (buffer: CVPixelBuffer, pts: CMTime)?
    private let cadence = ContentFrameCadenceDetector()
    private var counter = SourceFrameRateCounter(startTime: CACurrentMediaTime())
    private var anchor: (media: Double, host: Double)?
    private var lastReport = CACurrentMediaTime()
    private var enabled = false
    private var busy = false
    private var status = "插帧已关闭"
    private var delay: Double?
    private var failed = false
    #if !targetEnvironment(simulator)
    private var interpolator: AppleDownsampledFrameInterpolator?
    #endif

    static var supportsInterpolation: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return VTLowLatencyFrameInterpolationConfiguration.isSupported
        #endif
    }

    func reset(interpolation: Bool) {
        enabled = interpolation && Self.supportsInterpolation
        frames.reset()
        previous = nil
        cadence.reset()
        anchor = nil
        delay = nil
        busy = false
        failed = false
        counter.reset(at: CACurrentMediaTime())
        lastReport = CACurrentMediaTime()
        status = enabled ? "插帧准备中" : "插帧已关闭"
        #if !targetEnvironment(simulator)
        interpolator = nil
        #endif
    }

    func receive(_ buffer: CVPixelBuffer, pts: CMTime) {
        let now = CACurrentMediaTime()
        let media = CMTimeGetSeconds(pts)
        guard media.isFinite else { return }
        counter.record(at: now)
        let signature = enabled ? SwitchFrameCadenceDetector.makeDisplayFrameSignature(from: buffer) : nil
        let content = cadence.observe(signature: signature, time: media)
        if now - lastReport >= 1 {
            report?(counter.sample(at: now) ?? 0, content.observedFPS, status)
            lastReport = now
        }
        let aspect = Double(CVPixelBufferGetWidth(buffer)) / Double(CVPixelBufferGetHeight(buffer))
        let source = PreviewFrame(buffer: buffer, sourceAspect: aspect, receivedAt: now, interpolated: false)
        guard enabled, !failed else {
            frames.enqueue(source, mediaTime: media, displayTime: now, generation: frames.generation)
            previous = (buffer, pts)
            return
        }
        if content.isDiscontinuity {
            frames.reset()
            anchor = nil
            previous = nil
            delay = nil
        }
        guard !content.isDuplicate else { return }
        if anchor == nil { anchor = (media, now) }
        guard let anchor else { return }
        // Buffer enough time to receive the next source frame and synthesize its midpoint.
        // Keep this delay fixed per stream; changing it every frame causes pacing jumps.
        if delay == nil, let interval = content.updateInterval {
            delay = min(0.12, interval * 2 + 0.008)
        }
        let target = delay.map { anchor.host + media - anchor.media + $0 } ?? now
        let generation = frames.generation
        frames.enqueue(source, mediaTime: media, displayTime: target, generation: generation)
        defer { previous = (buffer, pts) }
        guard content.shouldInterpolate, let previous, !busy else { return }
        #if !targetEnvironment(simulator)
        do {
            if interpolator == nil {
                interpolator = try AppleDownsampledFrameInterpolator(
                    width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            }
            guard let interpolator else { return }
            busy = true
            let midpoint = (CMTimeGetSeconds(previous.pts) + media) / 2
            let midpointTarget = anchor.host + midpoint - anchor.media + (delay ?? 0.075)
            try interpolator.submit(previous: previous.buffer, current: buffer,
                                    previousPresentationTimeStamp: previous.pts,
                                    currentPresentationTimeStamp: pts) { [weak self] result, error in
                guard let self else { return }
                // Serialize completion with reset and the next source submission.
                self.completionQueue?.async { [weak self] in
                    guard let self, self.frames.generation == generation else { return }
                    self.busy = false
                    if let result {
                        let frame = PreviewFrame(buffer: result.pixelBuffer, sourceAspect: aspect,
                                                 receivedAt: now, interpolated: true)
                        if CACurrentMediaTime() < target {
                            self.frames.enqueue(frame, mediaTime: midpoint,
                                                displayTime: midpointTarget, generation: generation)
                        }
                        self.status = String(format: "Apple 插帧 · %.1f ms", result.processingMilliseconds)
                    } else if let error {
                        self.fallback(error)
                    }
                }
            }
        } catch {
            busy = false
            fallback(error)
        }
        #endif
    }

    var completionQueue: DispatchQueue?

    private func fallback(_ error: Error) {
        failed = true
        status = "插帧不可用，已恢复原始画面：\(error.localizedDescription)"
        frames.reset()
        #if !targetEnvironment(simulator)
        interpolator = nil
        #endif
        report?(0, nil, status)
    }
}
