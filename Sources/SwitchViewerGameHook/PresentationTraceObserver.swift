import CoreVideo
import QuartzCore
import SwitchViewerInterpolation

/// Recording-only clock observer. Never acquires a drawable or schedules output.
/// Core Video output timestamps are predictions, not physical scanout measurements.
final class PresentationTraceObserver {
    private var link: CVDisplayLink?
    private var displayID: CGDirectDisplayID?

    func observe(display: CGDirectDisplayID, trace: GameFrameTrace) {
        guard displayID != display else { return }
        stop()
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(display, &created) == kCVReturnSuccess,
              let created else { return }
        let status = CVDisplayLinkSetOutputHandler(created) { _, now, output, _, _ in
            let callback = CACurrentMediaTime()
            guard trace.isRecording(at: callback) else { return kCVReturnSuccess }
            let stamp = output.pointee
            let frequency = CVGetHostClockFrequency()
            guard frequency > 0, stamp.hostTime > 0,
                  stamp.flagOptions.contains(.hostTimeValid) else { return kCVReturnSuccess }
            // Anchor both clocks at this callback rather than assuming equal epochs.
            let hostNow = CVGetCurrentHostTime()
            let target = callback + (Double(stamp.hostTime) - Double(hostNow)) / frequency
            var event = GameFrameTrace.Event("displayTick", sequence: 0, time: callback)
            event.displayID = display
            event.requested = target
            if now.pointee.hostTime > 0 {
                event.ready = callback + (Double(now.pointee.hostTime) - Double(hostNow)) / frequency
            }
            if stamp.videoTimeScale > 0, stamp.videoRefreshPeriod > 0,
               stamp.flagOptions.contains(.videoRefreshPeriodValid) {
                event.refreshPeriod = Double(stamp.videoRefreshPeriod) / Double(stamp.videoTimeScale)
            }
            trace.record(event)
            return kCVReturnSuccess
        }
        guard status == kCVReturnSuccess, CVDisplayLinkStart(created) == kCVReturnSuccess else { return }
        link = created
        displayID = display
    }

    func stop() {
        if let link { CVDisplayLinkStop(link) }
        link = nil
        displayID = nil
    }

    deinit { stop() }
}
