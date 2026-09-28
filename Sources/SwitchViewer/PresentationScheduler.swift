import CoreMedia
import CoreVideo
import Foundation
import SwitchViewerInterpolation

struct CapturedSourceFrame {
    let id: UInt64
    let pixelBuffer: CVPixelBuffer
    let signature: DisplayFrameSignature?
    let presentationTimeStamp: CMTime
    let mediaHostTime: CFTimeInterval
    let captureCallbackHostTime: CFTimeInterval
    let epoch: Int
}

struct InterpolatedFrame {
    let previousSourcePresentationTimeStamp: CMTime
    let currentSourceID: UInt64
    let pixelBuffer: CVPixelBuffer
    let mediaPresentationTimeStamp: CMTime
    let mediaHostTime: CFTimeInterval
    let captureCallbackHostTime: CFTimeInterval
    let submittedHostTime: CFTimeInterval
    let readyHostTime: CFTimeInterval
    let epoch: Int
}

final class PresentationScheduler {
    private final class Slot {
        let key: Int64
        let mediaHostTime: CFTimeInterval
        var targetHostTime: CFTimeInterval
        var source: CapturedSourceFrame?
        var sourceIsDuplicate = false
        var sourceContentRootID: UInt64?
        var duplicateOfContentRootID: UInt64?
        var midpoint: InterpolatedFrame?
        var timer: DispatchSourceTimer?
        var wakeDeadlineHostTime: CFTimeInterval = 0
        var renderDeadlineHostTime: CFTimeInterval = 0

        init(key: Int64, mediaHostTime: CFTimeInterval, targetHostTime: CFTimeInterval) {
            self.key = key
            self.mediaHostTime = mediaHostTime
            self.targetHostTime = targetHostTime
        }
    }

    private let queue = DispatchQueue(label: "switchviewer.presentation-scheduler",
                                      qos: .userInteractive)
    private let onFrame: (PresentationFrame, Int) -> Void
    private let onReport: (String) -> Void
    private var epoch = 0
    private var slots: [Int64: Slot] = [:]
    private var latestSource: CapturedSourceFrame?
    private var latestSourceContentRootID: UInt64?
    private var lastPresentedSourceContentRootID: UInt64?
    private var requiredDelaySamples: [Double] = []
    private var renderLeadSamples: [Double] = []
    private var schedulerWakeLatenessSamples: [Double] = []
    private var midpointLateBySamples: [Double] = []
    private var signatureCompareTimeSamples: [Double] = []
    // Start close to the measured end-to-end readiness budget. The estimator can
    // raise this when real midpoint completion requires more headroom.
    private let initialPlayoutDelayMilliseconds = 75.0
    private var playoutDelayMilliseconds = 75.0
    private var lastDelayDecreaseUptime = ProcessInfo.processInfo.systemUptime
    private var lastReportUptime = ProcessInfo.processInfo.systemUptime
    private var sourceSlotCount = 0
    private var midpointSlotCount = 0
    private var heldSlotCount = 0
    private var lateMidpointDropCount = 0
    private var sourceFallbackCount = 0
    private var midpointSupersededBySourceCount = 0
    private var signatureCompareCount = 0
    private var signatureDuplicateCount = 0

    init(onFrame: @escaping (PresentationFrame, Int) -> Void,
         onReport: @escaping (String) -> Void) {
        self.onFrame = onFrame
        self.onReport = onReport
    }

    func reset(epoch: Int, preservingLearnedTiming: Bool = false) {
        queue.async {
            for slot in self.slots.values { slot.timer?.cancel() }
            self.slots.removeAll(keepingCapacity: true)
            self.latestSource = nil
            self.latestSourceContentRootID = nil
            self.lastPresentedSourceContentRootID = nil
            self.epoch = epoch
            if !preservingLearnedTiming {
                self.requiredDelaySamples.removeAll(keepingCapacity: true)
                self.renderLeadSamples.removeAll(keepingCapacity: true)
                self.schedulerWakeLatenessSamples.removeAll(keepingCapacity: true)
                self.playoutDelayMilliseconds = self.initialPlayoutDelayMilliseconds
            }
            self.midpointLateBySamples.removeAll(keepingCapacity: true)
            self.signatureCompareTimeSamples.removeAll(keepingCapacity: true)
            self.lastDelayDecreaseUptime = ProcessInfo.processInfo.systemUptime
            self.sourceSlotCount = 0
            self.midpointSlotCount = 0
            self.heldSlotCount = 0
            self.lateMidpointDropCount = 0
            self.sourceFallbackCount = 0
            self.midpointSupersededBySourceCount = 0
            self.signatureCompareCount = 0
            self.signatureDuplicateCount = 0
        }
    }

    func offerSource(_ frame: CapturedSourceFrame) {
        queue.async {
            guard frame.epoch == self.epoch else { return }
            let previous = self.latestSource
            var isDuplicate = false
            if let previousSignature = previous?.signature,
               let currentSignature = frame.signature {
                self.signatureCompareCount += 1
                let compareStart = ProcessInfo.processInfo.systemUptime
                isDuplicate = previousSignature == currentSignature
                self.signatureCompareTimeSamples.append(
                    (ProcessInfo.processInfo.systemUptime - compareStart) * 1_000)
                if self.signatureCompareTimeSamples.count > 180 {
                    self.signatureCompareTimeSamples.removeFirst(
                        self.signatureCompareTimeSamples.count - 180)
                }
                if isDuplicate { self.signatureDuplicateCount += 1 }
            }
            let contentRootID = isDuplicate
                ? (self.latestSourceContentRootID ?? frame.id)
                : frame.id
            let scheduledFrame: CapturedSourceFrame
            if isDuplicate, let previous {
                // Reuse the last known buffer for this sampled content so duplicate
                // capture buffers do not remain retained for the playout delay.
                scheduledFrame = CapturedSourceFrame(
                    id: frame.id,
                    pixelBuffer: previous.pixelBuffer,
                    signature: frame.signature,
                    presentationTimeStamp: frame.presentationTimeStamp,
                    mediaHostTime: frame.mediaHostTime,
                    captureCallbackHostTime: frame.captureCallbackHostTime,
                    epoch: frame.epoch)
            } else {
                scheduledFrame = frame
            }
            self.latestSource = scheduledFrame
            self.latestSourceContentRootID = contentRootID
            let slot = self.slot(for: frame.mediaHostTime)
            slot.source = scheduledFrame
            slot.sourceIsDuplicate = isDuplicate
            slot.sourceContentRootID = contentRootID
            slot.duplicateOfContentRootID = isDuplicate ? contentRootID : nil
            self.sourceSlotCount += 1
            self.schedule(slot)
        }
    }

    func offerMidpoint(_ frame: InterpolatedFrame) {
        queue.async {
            guard frame.epoch == self.epoch else { return }
            self.observeRequiredDelay(frame)
            let slot = self.slot(for: frame.mediaHostTime)
            let now = Self.hostTimeNow
            if slot.targetHostTime - now
                < (self.renderLeadP99Milliseconds + self.deadlineSafetyMilliseconds) / 1_000 {
                self.lateMidpointDropCount += 1
                let latestReadyDeadline = slot.targetHostTime
                    - (self.renderLeadP99Milliseconds + self.deadlineSafetyMilliseconds) / 1_000
                self.midpointLateBySamples.append(max(0, (now - latestReadyDeadline) * 1_000))
                if self.midpointLateBySamples.count > 180 {
                    self.midpointLateBySamples.removeFirst(
                        self.midpointLateBySamples.count - 180)
                }
                if slot.source == nil { self.slots.removeValue(forKey: slot.key) }
                else { self.schedule(slot) }
                self.reportIfNeeded()
                return
            }
            slot.midpoint = frame
            self.midpointSlotCount += 1
            self.schedule(slot)
        }
    }

    func recordSourcePresented(_ sourceID: UInt64?, contentRootID: UInt64?) {
        guard let sourceID else { return }
        queue.async {
            self.lastPresentedSourceContentRootID = contentRootID ?? sourceID
        }
    }

    func recordRendererLead(_ milliseconds: Double?) {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return }
        queue.async {
            self.renderLeadSamples.append(milliseconds)
            if self.renderLeadSamples.count > 180 {
                self.renderLeadSamples.removeFirst(self.renderLeadSamples.count - 180)
            }
        }
    }

    private var renderLeadP99Milliseconds: Double {
        Self.percentile(renderLeadSamples, 0.99) ?? 4.0
    }

    private var deadlineSafetyMilliseconds: Double {
        max(0.25, (Self.percentile(schedulerWakeLatenessSamples, 0.99) ?? 0.5) + 0.25)
    }

    private func retimePendingSlots() {
        for slot in slots.values {
            let updatedTarget = max(slot.targetHostTime,
                                    slot.mediaHostTime + playoutDelayMilliseconds / 1_000)
            guard updatedTarget > slot.targetHostTime else { continue }
            slot.targetHostTime = updatedTarget
            slot.timer?.cancel()
            slot.timer = nil
            schedule(slot)
        }
    }

    private func observeRequiredDelay(_ frame: InterpolatedFrame) {
        let required = max(0, frame.readyHostTime - frame.mediaHostTime) * 1_000
            + renderLeadP99Milliseconds + deadlineSafetyMilliseconds
        requiredDelaySamples.append(required)
        if requiredDelaySamples.count > 180 {
            requiredDelaySamples.removeFirst(requiredDelaySamples.count - 180)
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard requiredDelaySamples.count >= 60,
              let p99 = Self.percentile(requiredDelaySamples, 0.99) else { return }
        if p99 > playoutDelayMilliseconds {
            playoutDelayMilliseconds = p99
            lastDelayDecreaseUptime = now
            retimePendingSlots()
        } else if p99 < playoutDelayMilliseconds,
                  now - lastDelayDecreaseUptime >= 1 {
            let elapsed = now - lastDelayDecreaseUptime
            let maximumDecrease = elapsed * 1.0
            playoutDelayMilliseconds = max(p99, playoutDelayMilliseconds - maximumDecrease)
            lastDelayDecreaseUptime = now
        }
    }

    private func slot(for mediaHostTime: CFTimeInterval) -> Slot {
        let roundedMillisecond = Int64((mediaHostTime * 1_000).rounded())
        for offset in -2...2 {
            let candidateKey = roundedMillisecond + Int64(offset)
            if let slot = slots[candidateKey],
               abs(slot.mediaHostTime - mediaHostTime) <= 0.002 {
                let updatedTarget = max(slot.targetHostTime,
                                        mediaHostTime + playoutDelayMilliseconds / 1_000)
                if updatedTarget > slot.targetHostTime {
                    slot.targetHostTime = updatedTarget
                    slot.timer?.cancel()
                    slot.timer = nil
                }
                return slot
            }
        }
        let key = roundedMillisecond
        let target = mediaHostTime + playoutDelayMilliseconds / 1_000
        let slot = Slot(key: key, mediaHostTime: mediaHostTime, targetHostTime: target)
        slots[key] = slot
        return slot
    }

    private func schedule(_ slot: Slot) {
        guard slot.timer == nil else { return }
        let renderLead = renderLeadP99Milliseconds / 1_000
        let safety = deadlineSafetyMilliseconds / 1_000
        slot.renderDeadlineHostTime = slot.targetHostTime - renderLead
        slot.wakeDeadlineHostTime = slot.renderDeadlineHostTime - safety
        let delay = max(0, slot.wakeDeadlineHostTime - Self.hostTimeNow)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.fire(slot)
        }
        slot.timer = timer
        timer.resume()
    }

    private func fire(_ slot: Slot) {
        guard slots[slot.key] === slot else { return }
        slots.removeValue(forKey: slot.key)
        slot.timer?.cancel()
        slot.timer = nil
        let now = Self.hostTimeNow
        let wakeLatenessMilliseconds = max(0, (now - slot.wakeDeadlineHostTime) * 1_000)
        schedulerWakeLatenessSamples.append(wakeLatenessMilliseconds)
        if schedulerWakeLatenessSamples.count > 180 {
            schedulerWakeLatenessSamples.removeFirst(
                schedulerWakeLatenessSamples.count - 180)
        }
        let deadlineMissed = now > slot.renderDeadlineHostTime

        let selected: PresentationFrame?
        if let source = slot.source, !slot.sourceIsDuplicate {
            if slot.midpoint != nil { midpointSupersededBySourceCount += 1 }
            selected = makeFrame(from: source, target: deadlineMissed ? nil : slot.targetHostTime,
                                 contentRootID: slot.sourceContentRootID)
        } else if slot.source != nil,
                  let midpoint = slot.midpoint,
                  !deadlineMissed {
            selected = makeFrame(from: midpoint, target: slot.targetHostTime,
                                 captureCallbackHostTime: midpoint.captureCallbackHostTime)
        } else if let source = slot.source,
                  slot.duplicateOfContentRootID != lastPresentedSourceContentRootID {
            if slot.midpoint != nil { lateMidpointDropCount += 1 }
            sourceFallbackCount += 1
            selected = makeFrame(from: source, target: deadlineMissed ? nil : slot.targetHostTime,
                                 contentRootID: slot.sourceContentRootID)
        } else if let midpoint = slot.midpoint, !deadlineMissed {
            selected = makeFrame(from: midpoint, target: slot.targetHostTime,
                                 captureCallbackHostTime: midpoint.captureCallbackHostTime)
        } else {
            if slot.midpoint != nil { lateMidpointDropCount += 1 }
            heldSlotCount += 1
            selected = nil
        }
        if let selected { onFrame(selected, epoch) }
        reportIfNeeded()
    }

    private func makeFrame(from source: CapturedSourceFrame,
                           target: CFTimeInterval?,
                           contentRootID: UInt64?) -> PresentationFrame {
        PresentationFrame(pixelBuffer: source.pixelBuffer,
                          displaySignature: source.signature,
                          isInterpolated: false,
                          minimumPresentationDuration: nil,
                          presentationTimestampHostTime: source.mediaHostTime,
                          targetPresentationHostTime: target,
                          sourceID: source.id,
                          sourceContentRootID: contentRootID,
                          timing: PresentationFrameTiming(
                            captureCallbackHostTime: source.captureCallbackHostTime,
                            processingReadyHostTime: source.captureCallbackHostTime))
    }

    private func makeFrame(from midpoint: InterpolatedFrame,
                           target: CFTimeInterval,
                           captureCallbackHostTime: CFTimeInterval) -> PresentationFrame {
        PresentationFrame(pixelBuffer: midpoint.pixelBuffer, isInterpolated: true,
                          minimumPresentationDuration: nil,
                          presentationTimestampHostTime: midpoint.mediaHostTime,
                          targetPresentationHostTime: target,
                          sourceID: nil,
                          timing: PresentationFrameTiming(
                            captureCallbackHostTime: captureCallbackHostTime,
                            processingReadyHostTime: midpoint.readyHostTime))
    }

    private func reportIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReportUptime >= 3 else { return }
        lastReportUptime = now
        let lateP50 = Self.percentile(midpointLateBySamples, 0.50)
        let lateP95 = Self.percentile(midpointLateBySamples, 0.95)
        let lateP99 = Self.percentile(midpointLateBySamples, 0.99)
        let wakeP99 = Self.percentile(schedulerWakeLatenessSamples, 0.99)
        let compareP50 = Self.percentile(signatureCompareTimeSamples, 0.50)
        let compareP95 = Self.percentile(signatureCompareTimeSamples, 0.95)
        let compareP99 = Self.percentile(signatureCompareTimeSamples, 0.99)
        onReport("deadline scheduler; sourceOffers=\(sourceSlotCount) midpointOffers=\(midpointSlotCount) heldSlots=\(heldSlotCount); lateMidpointDrops=\(lateMidpointDropCount); midpointLateByP50P95P99Ms=\(lateP50.map { String(format: "%.1f", $0) } ?? "无")/\(lateP95.map { String(format: "%.1f", $0) } ?? "无")/\(lateP99.map { String(format: "%.1f", $0) } ?? "无"); sourceFallbacks=\(sourceFallbackCount); midpointSupersededBySource=\(midpointSupersededBySourceCount); signatureCompare=\(signatureCompareCount); signatureDuplicate=\(signatureDuplicateCount); signatureCompareP50P95P99Ms=\(compareP50.map { String(format: "%.3f", $0) } ?? "无")/\(compareP95.map { String(format: "%.3f", $0) } ?? "无")/\(compareP99.map { String(format: "%.3f", $0) } ?? "无"); playoutDelayP99Ms=\(String(format: "%.1f", playoutDelayMilliseconds)); renderLeadP99Ms=\(String(format: "%.1f", renderLeadP99Milliseconds)); schedulerWakeLatenessP99Ms=\(wakeP99.map { String(format: "%.2f", $0) } ?? "无"); deadlineSafetyMs=\(String(format: "%.2f", deadlineSafetyMilliseconds))")
        sourceSlotCount = 0
        midpointSlotCount = 0
        heldSlotCount = 0
        lateMidpointDropCount = 0
        sourceFallbackCount = 0
        midpointSupersededBySourceCount = 0
        signatureCompareCount = 0
        signatureDuplicateCount = 0
        signatureCompareTimeSamples.removeAll(keepingCapacity: true)
        midpointLateBySamples.removeAll(keepingCapacity: true)
    }

    private static var hostTimeNow: CFTimeInterval {
        presentationHostTimeNow()
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1,
                        max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

}
