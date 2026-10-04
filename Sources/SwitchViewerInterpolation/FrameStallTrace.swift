import Foundation
import QuartzCore

/// 游戏内插帧显示路径的逐帧埋点。
///
/// 现有的周期指标只有 1 秒粒度的 P50，单帧尖峰会被中位数吃掉；而且显示调度里
/// 有十几条静默 return 路径，一条日志都不留。这个类型做三件事：
///
/// 1. 给每条静默路径一个计数器，把"帧根本没提交上去"和"提交了但没上屏"分开；
/// 2. 维护一个逐帧环形缓冲，在检测到停顿的瞬间把停顿前后的原始事件倒出来；
/// 3. 提供不依赖上屏回调的窗口统计，显示路径整体挂掉时日志也不会静默。
///
/// 线程安全：采集回调、工作队列、Metal 上屏回调都会写，内部用锁串行化。
public final class FrameStallTrace {
    public enum Kind: UInt8, CaseIterable {
        case captured, planned, dropped, submitted, presented, unconfirmed, rebuilt, hidden, shown, skipped
    }

    /// 每个静默 return 路径对应一个计数器。`label` 会直接出现在日志里。
    public enum Counter: UInt8, CaseIterable {
        // 采集侧
        case captureEntered
        case captureSkippedBusy
        case captureSkippedPaused
        case captureSkippedOtherLayer
        case captureNoTexture
        case captureGpuFailed
        // 处理侧
        case rebuild
        case convertFailed
        case interpolateSubmitted
        case interpolateCompleted
        case interpolateFailed
        case interpolateSkippedBusy
        // 显示调度侧
        case scheduleAttempt
        case dropPaused
        case dropStaleEpoch
        case dropNotReady
        case dropStaleSequence
        case dropExpired
        case dropRetryWait
        case dropLate
        case dropMissingResource
        case dropNoSlot
        case dropNoDrawable
        case dropNoCommandBuffer
        case dropEncodeFailed
        case dropPastExpiry
        case submitted
        // 上屏侧
        case presented
        case presentedUnconfirmed
        case presentedStaleEpoch
        case midpointDroppedNotUseful
        // 看门狗
        case hiddenStaleReady
        case hiddenNoDisplay
        case shownAfterSubmit

        public var label: String {
            switch self {
            case .captureEntered: return "cap"
            case .captureSkippedBusy: return "capSkipBusy"
            case .captureSkippedPaused: return "capSkipPaused"
            case .captureSkippedOtherLayer: return "capSkipOtherLayer"
            case .captureNoTexture: return "capNoTexture"
            case .captureGpuFailed: return "capGpuFail"
            case .rebuild: return "rebuild"
            case .convertFailed: return "processFail"
            case .interpolateSubmitted: return "itpSubmit"
            case .interpolateCompleted: return "itpDone"
            case .interpolateFailed: return "itpFail"
            case .interpolateSkippedBusy: return "itpSkipBusy"
            case .scheduleAttempt: return "sched"
            case .dropPaused: return "dropPaused"
            case .dropStaleEpoch: return "dropStaleEpoch"
            case .dropNotReady: return "dropNotReady"
            case .dropStaleSequence: return "dropStaleSeq"
            case .dropExpired: return "dropExpired"
            case .dropRetryWait: return "dropRetryWait"
            case .dropLate: return "dropLate"
            case .dropMissingResource: return "dropNoResource"
            case .dropNoSlot: return "dropNoSlot"
            case .dropNoDrawable: return "dropNoDrawable"
            case .dropNoCommandBuffer: return "dropNoCmdBuf"
            case .dropEncodeFailed: return "dropEncodeFail"
            case .dropPastExpiry: return "dropPastExpiry"
            case .submitted: return "submit"
            case .presented: return "present"
            case .presentedUnconfirmed: return "presentTime0"
            case .presentedStaleEpoch: return "presentStaleEpoch"
            case .midpointDroppedNotUseful: return "midDropLate"
            case .hiddenStaleReady: return "hideStaleReady"
            case .hiddenNoDisplay: return "hideNoDisplay"
            case .shownAfterSubmit: return "show"
            }
        }

        /// 只把"值得单独看一眼"的计数放进周期行，正常路径不刷屏。
        public var isDropReason: Bool {
            switch self {
            case .dropPaused, .dropStaleEpoch, .dropNotReady, .dropStaleSequence,
                 .dropExpired, .dropRetryWait, .dropLate, .dropMissingResource,
                 .dropNoSlot, .dropNoDrawable, .dropNoCommandBuffer, .dropEncodeFailed,
                 .dropPastExpiry, .midpointDroppedNotUseful, .captureSkippedBusy,
                 .captureSkippedOtherLayer, .captureNoTexture, .captureGpuFailed,
                 .convertFailed, .interpolateFailed, .interpolateSkippedBusy,
                 .presentedUnconfirmed, .hiddenStaleReady, .hiddenNoDisplay:
                return true
            default:
                return false
            }
        }
    }

    /// 周期指标窗口。`gapMax`/`ageMax` 这类最大值是原来的 P50 指标看不到的。
    public struct Window {
        public let counters: [(label: String, count: Int)]
        public let scheduleAttempts: Int
        public let submissions: Int
        public let presentations: Int
        public let presentationGapMaxMilliseconds: Double
        public let presentationGapCount: Int
        public let captureGapMaxMilliseconds: Double
        public let captureGapCount: Int
        public let contentAgeMaxMilliseconds: Double
        public let targetErrorMaxMilliseconds: Double
        public let submitToPresentMaxMilliseconds: Double
        /// 已提交但还没有确认上屏的 drawable 数。持续 > 0 说明"提交了没上屏"。
        public let pendingSubmissions: Int
        public let submittedTotal: Int
        public let presentedTotal: Int
    }

    public struct StallReport {
        public let kind: String
        public let gapMilliseconds: Double
        public let at: Double
        public let lines: [String]
    }

    private struct Event {
        var time: Double = 0
        var kind: Kind = .captured
        var code: UInt8 = 0
        var sequence: UInt64 = 0
        var a: Double = 0
        var b: Double = 0
        var c: Double = 0
        var d: Double = 0
        var note: String = ""
    }

    private let lock = NSLock()
    private let capacity: Int
    private var events: [Event]
    /// 下一个事件要用的序号。序号单调递增，缓冲是环形的，用取模定位。
    private var nextSerial: UInt64 = 0

    private var counters = [Int](repeating: 0, count: Counter.allCases.count)
    private var windowCounters = [Int](repeating: 0, count: Counter.allCases.count)

    private var lastCaptureTime: Double?
    private var lastCaptureSerial: UInt64 = 0
    private var lastPresentationTime: Double?
    private var lastPresentationSerial: UInt64 = 0

    private var captureGapMax: Double = 0
    private var captureGapCount = 0
    private var presentationGapMax: Double = 0
    private var presentationGapCount = 0
    private var contentAgeMax: Double = 0
    private var targetErrorMax: Double = 0
    private var submitToPresentMax: Double = 0

    private var submittedTotal = 0
    private var presentedTotal = 0
    private var pendingSubmissions = 0
    private var scheduleAttempts = 0
    private var submissions = 0
    private var presentations = 0

    private struct Episode {
        var active = false
        var dumps = 0
        var lastReport: Double = -.infinity
    }

    private var episodes: [String: Episode] = [:]
    private var pendingReports: [StallReport] = []

    public let presentationGapThreshold: Double
    public let captureGapThreshold: Double
    /// 完全没有上屏回调多久就判定为"显示静默"（秒）。
    /// 这是"两次上屏之间的间隔"覆盖不到的情形：一帧都没提交时不会有下一次上屏，
    /// 只能靠外部探针发现——那正是几分钟中断的形状。
    public let presentationSilenceThreshold: Double
    public let reportCooldown: Double
    /// 同一轮停顿最多倒带几次。一次几分钟的中断会持续产生停顿，
    /// 不设上限就会用倒带把日志淹掉；恢复一次正常间隔后重新计数。
    public let maxDumpsPerEpisode: Int
    /// 倒带时打印的"触发点之后"与"恢复点之前"的最大行数。
    public let rewindHeadLines: Int
    public let rewindTailLines: Int
    public let rewindPreContext: Int

    /// - Parameters:
    ///   - capacity: 环形缓冲条数。约 240 事件/秒，1024 条覆盖约 4 秒上下文。
    ///   - presentationGapThreshold: 相邻两次上屏超过这个间隔就判定为停顿（秒）。
    ///   - captureGapThreshold: 相邻两次采集超过这个间隔就判定为游戏侧停顿（秒）。
    ///   - presentationSilenceThreshold: 完全没有上屏多久就判定为显示静默（秒）。
    ///   - reportCooldown: 同一轮内两次倒带报告的最小间隔。
    ///   - maxDumpsPerEpisode: 同一轮停顿最多倒带几次。
    ///   - rewindHeadLines: 停顿开始后最多打印多少条，用来抓触发原因。
    ///   - rewindTailLines: 停顿结束前最多打印多少条，用来抓恢复过程。
    public init(capacity: Int = 1024,
                presentationGapThreshold: Double = 0.060,
                captureGapThreshold: Double = 0.080,
                presentationSilenceThreshold: Double = 0.500,
                reportCooldown: Double = 2.0,
                maxDumpsPerEpisode: Int = 3,
                rewindHeadLines: Int = 60,
                rewindTailLines: Int = 25,
                rewindPreContext: Int = 20) {
        self.capacity = max(16, capacity)
        self.events = Array(repeating: Event(), count: self.capacity)
        self.presentationGapThreshold = presentationGapThreshold
        self.captureGapThreshold = captureGapThreshold
        self.presentationSilenceThreshold = presentationSilenceThreshold
        self.reportCooldown = reportCooldown
        self.maxDumpsPerEpisode = max(1, maxDumpsPerEpisode)
        self.rewindHeadLines = max(0, rewindHeadLines)
        self.rewindTailLines = max(0, rewindTailLines)
        self.rewindPreContext = max(0, rewindPreContext)
    }

    // MARK: - 记录

    @discardableResult
    public func count(_ counter: Counter) -> Int {
        lock.lock()
        defer { lock.unlock() }
        counters[Int(counter.rawValue)] += 1
        windowCounters[Int(counter.rawValue)] += 1
        switch counter {
        case .scheduleAttempt: scheduleAttempts += 1
        case .submitted: submissions += 1
        case .presented: presentations += 1
        default: break
        }
        return counters[Int(counter.rawValue)]
    }

    /// 采集到一帧游戏画面。返回距上一帧的间隔（秒）。
    @discardableResult
    public func noteCaptured(time: Double, width: Int, height: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let gap = lastCaptureTime.map { time - $0 } ?? 0
        let intervalStart = lastCaptureSerial
        lastCaptureTime = time
        var event = Event(time: time, kind: .captured, sequence: 0)
        event.a = Double(width)
        event.b = Double(height)
        event.c = gap * 1_000
        lastCaptureSerial = append(event)
        captureGapMax = max(captureGapMax, gap)
        if gap > captureGapThreshold {
            captureGapCount += 1
            enqueueReportLocked(kind: "captureGap", gap: gap, at: time, stallStartSerial: intervalStart)
        } else {
            endEpisodeLocked("captureGap")
        }
        return gap
    }

    public func noteConverted(time: Double, milliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        var event = Event(time: time, kind: .skipped, sequence: 0)
        event.note = String(format: "conv %.2fms", milliseconds)
        append(event)
    }

    /// 几何变化导致整条显示链重建。这是重点怀疑对象，单独记一条。
    public func noteRebuilt(time: Double, from: String, to: String,
                            converterMilliseconds: Double,
                            interpolatorMilliseconds: Double,
                            overlayMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        var event = Event(time: time, kind: .rebuilt, sequence: 0)
        event.a = converterMilliseconds
        event.b = interpolatorMilliseconds
        event.c = overlayMilliseconds
        event.note = "\(from)->\(to)"
        append(event)
    }

    public func notePlanned(time: Double, sequence: UInt64,
                            deadline: Double, expires: Double, prequeued: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var event = Event(time: time, kind: .planned, sequence: sequence)
        event.a = (deadline - time) * 1_000
        event.b = (expires - time) * 1_000
        event.c = prequeued ? 1 : 0
        append(event)
    }

    public func noteDropped(time: Double, sequence: UInt64, reason: Counter,
                            deadline: Double, expires: Double) {
        lock.lock()
        defer { lock.unlock() }
        counters[Int(reason.rawValue)] += 1
        windowCounters[Int(reason.rawValue)] += 1
        var event = Event(time: time, kind: .dropped, code: reason.rawValue, sequence: sequence)
        event.a = (deadline - time) * 1_000
        event.b = (expires - time) * 1_000
        event.note = reason.label
        append(event)
    }

    public func noteSubmitted(time: Double, sequence: UInt64,
                              deadline: Double, expires: Double,
                              drawableWaitMilliseconds: Double,
                              encodeMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        counters[Int(Counter.submitted.rawValue)] += 1
        windowCounters[Int(Counter.submitted.rawValue)] += 1
        submittedTotal += 1
        submissions += 1
        pendingSubmissions += 1
        var event = Event(time: time, kind: .submitted, sequence: sequence)
        event.a = drawableWaitMilliseconds
        event.b = encodeMilliseconds
        event.c = (deadline - time) * 1_000
        event.d = (expires - time) * 1_000
        append(event)
    }

    /// 上屏回调确认（`presentedTime > 0`）。
    public func notePresented(time: Double, sequence: UInt64,
                              sourceTime: Double, submitTime: Double,
                              deadline: Double, drawableWaitMilliseconds: Double,
                              encodeMilliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        counters[Int(Counter.presented.rawValue)] += 1
        windowCounters[Int(Counter.presented.rawValue)] += 1
        presentedTotal += 1
        presentations += 1
        pendingSubmissions = max(0, pendingSubmissions - 1)

        let gap = lastPresentationTime.map { time - $0 } ?? 0
        let intervalStart = lastPresentationSerial
        lastPresentationTime = time
        let age = (time - sourceTime) * 1_000
        let targetError = (time - deadline) * 1_000
        let submitToPresent = (time - submitTime) * 1_000

        contentAgeMax = max(contentAgeMax, age)
        targetErrorMax = max(targetErrorMax, targetError)
        submitToPresentMax = max(submitToPresentMax, submitToPresent)
        presentationGapMax = max(presentationGapMax, gap)

        var event = Event(time: time, kind: .presented, sequence: sequence)
        event.a = gap * 1_000
        event.b = age
        event.c = targetError
        event.d = drawableWaitMilliseconds
        event.note = String(format: "enc=%.2fms", encodeMilliseconds)
        lastPresentationSerial = append(event)

        if gap > presentationGapThreshold {
            presentationGapCount += 1
            enqueueReportLocked(kind: "presentationGap", gap: gap, at: time, stallStartSerial: intervalStart)
        } else {
            endEpisodeLocked("presentationGap")
        }
        // 上屏恢复，静默轮次结束。
        endEpisodeLocked("noPresentation")
    }

    /// 上屏回调拿到 `presentedTime == 0`：提交了但系统没确认上屏。
    ///
    /// 回调本身到了，drawable 会被回收，所以这里也把 `pending` 减掉；
    /// 这样 `pending` 只表示"完全没有回调"，是真正的泄漏信号，
    /// 而 `presentTime0` 单独统计"回调了但没上屏"。
    public func noteUnconfirmed(time: Double, sequence: UInt64, submitTime: Double) {
        lock.lock()
        defer { lock.unlock() }
        counters[Int(Counter.presentedUnconfirmed.rawValue)] += 1
        windowCounters[Int(Counter.presentedUnconfirmed.rawValue)] += 1
        pendingSubmissions = max(0, pendingSubmissions - 1)
        var event = Event(time: time, kind: .unconfirmed, sequence: sequence)
        event.a = (time - submitTime) * 1_000
        append(event)
    }

    public func noteHidden(time: Double, reason: Counter) {
        lock.lock()
        defer { lock.unlock() }
        counters[Int(reason.rawValue)] += 1
        windowCounters[Int(reason.rawValue)] += 1
        var event = Event(time: time, kind: .hidden, code: reason.rawValue)
        event.note = reason.label
        append(event)
    }

    public func noteShown(time: Double, sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        counters[Int(Counter.shownAfterSubmit.rawValue)] += 1
        windowCounters[Int(Counter.shownAfterSubmit.rawValue)] += 1
        var event = Event(time: time, kind: .shown, sequence: sequence)
        event.note = "unhide"
        append(event)
    }

    public func noteSkipped(time: Double, note: String) {
        lock.lock()
        defer { lock.unlock() }
        var event = Event(time: time, kind: .skipped)
        event.note = note
        append(event)
    }

    /// 外部探针（看门狗每 0.2s 调一次）：发现长时间完全没有上屏就倒带。
    ///
    /// "两次上屏之间的间隔"必须等下一次上屏才能算出来；如果显示路径彻底不提交了，
    /// 就永远等不到那一次，也就永远不会触发。这条路径专门覆盖那种几分钟的中断。
    /// 同时把静默时长计入窗口最大值，让 `TRACE` 行直接显示中断有多长。
    public func probe(time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastPresentationTime else { return }
        let silence = time - last
        guard silence > presentationSilenceThreshold else { return }
        presentationGapMax = max(presentationGapMax, silence)
        enqueueReportLocked(kind: "noPresentation", gap: silence, at: time,
                            stallStartSerial: lastPresentationSerial)
    }

    // MARK: - 读取

    /// 取出待打印的倒带报告。
    public func takeStallReports() -> [StallReport] {
        lock.lock()
        defer { lock.unlock() }
        let reports = pendingReports
        pendingReports.removeAll(keepingCapacity: true)
        return reports
    }

    /// 取本窗口指标并清零窗口统计。计数为增量，便于看"这一秒发生了什么"。
    public func takeWindow() -> Window {
        lock.lock()
        defer { lock.unlock() }
        var deltas: [(String, Int)] = []
        for counter in Counter.allCases where counter.isDropReason {
            let value = windowCounters[Int(counter.rawValue)]
            if value > 0 { deltas.append((counter.label, value)) }
        }
        windowCounters = [Int](repeating: 0, count: Counter.allCases.count)
        let window = Window(counters: deltas,
                            scheduleAttempts: scheduleAttempts,
                            submissions: submissions,
                            presentations: presentations,
                            presentationGapMaxMilliseconds: presentationGapMax * 1_000,
                            presentationGapCount: presentationGapCount,
                            captureGapMaxMilliseconds: captureGapMax * 1_000,
                            captureGapCount: captureGapCount,
                            contentAgeMaxMilliseconds: contentAgeMax,
                            targetErrorMaxMilliseconds: targetErrorMax,
                            submitToPresentMaxMilliseconds: submitToPresentMax,
                            pendingSubmissions: pendingSubmissions,
                            submittedTotal: submittedTotal,
                            presentedTotal: presentedTotal)
        scheduleAttempts = 0
        submissions = 0
        presentations = 0
        presentationGapMax = 0
        presentationGapCount = 0
        captureGapMax = 0
        captureGapCount = 0
        contentAgeMax = 0
        targetErrorMax = 0
        submitToPresentMax = 0
        return window
    }

    /// 累计计数快照，用于停机前的总结。
    public func counterSummary() -> [(label: String, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return Counter.allCases.compactMap { counter in
            let value = counters[Int(counter.rawValue)]
            return value > 0 ? (counter.label, value) : nil
        }
    }

    // MARK: - 内部

    @discardableResult
    private func append(_ event: Event) -> UInt64 {
        let serial = nextSerial
        events[Int(serial % UInt64(capacity))] = event
        nextSerial &+= 1
        return serial
    }

    /// 调用方必须已持锁。
    /// 每轮停顿独立限流：采集停顿不会压掉显示停顿的倒带（两者根因完全不同）。
    private func enqueueReportLocked(kind: String, gap: Double, at: Double, stallStartSerial: UInt64) {
        var episode = episodes[kind] ?? Episode()
        episode.active = true
        guard episode.dumps < maxDumpsPerEpisode, at - episode.lastReport >= reportCooldown else {
            episodes[kind] = episode
            return
        }
        episode.dumps += 1
        episode.lastReport = at
        episodes[kind] = episode
        pendingReports.append(StallReport(kind: kind, gapMilliseconds: gap * 1_000, at: at,
                                          lines: rewindLinesLocked(stallStartSerial: stallStartSerial)))
        if pendingReports.count > 6 { pendingReports.removeFirst(pendingReports.count - 6) }
    }

    /// 调用方必须已持锁。一次正常间隔代表本轮停顿结束。
    private func endEpisodeLocked(_ kind: String) {
        guard var episode = episodes[kind], episode.active else { return }
        episode.active = false
        episode.dumps = 0
        episodes[kind] = episode
    }

    /// 停顿可能持续几分钟、积累上万条事件，全量倒带会淹掉日志。
    /// 只打印两段：触发点附近（为什么开始）和恢复点附近（怎么结束的）。
    private func rewindLinesLocked(stallStartSerial: UInt64) -> [String] {
        let oldest = nextSerial > UInt64(capacity) ? nextSerial - UInt64(capacity) : 0
        let start = max(oldest, stallStartSerial > UInt64(rewindPreContext)
            ? stallStartSerial - UInt64(rewindPreContext) : 0)
        let end = nextSerial
        guard end > start else { return [] }

        let total = Int(end - start)
        var serials: [UInt64] = []
        if total <= rewindHeadLines + rewindTailLines {
            serials = Array(start..<end)
        } else {
            serials = Array(start..<(start + UInt64(rewindHeadLines)))
            serials.append(UInt64.max)
            serials.append(contentsOf: (end - UInt64(rewindTailLines))..<end)
        }

        let reference = eventLocked(at: start)?.time ?? 0
        return serials.map { serial in
            if serial == UInt64.max {
                return "        …… 省略 \(total - rewindHeadLines - rewindTailLines) 条 ……"
            }
            guard let event = eventLocked(at: serial) else { return "        ?" }
            return format(event, reference: reference)
        }
    }

    private func eventLocked(at serial: UInt64) -> Event? {
        let oldest = nextSerial > UInt64(capacity) ? nextSerial - UInt64(capacity) : 0
        guard serial >= oldest, serial < nextSerial else { return nil }
        return events[Int(serial % UInt64(capacity))]
    }

    private func format(_ event: Event, reference: Double) -> String {
        let t = String(format: "%+9.1f", (event.time - reference) * 1_000)
        switch event.kind {
        case .captured:
            return String(format: "%@ cap   %4.0fx%-5.0f gap=%.1fms", t, event.a, event.b, event.c)
        case .planned:
            return String(format: "%@ plan  seq=%-6llu dl=%+.1fms exp=%+.1fms pre=%.0f",
                          t, event.sequence, event.a, event.b, event.c)
        case .dropped:
            return String(format: "%@ DROP  seq=%-6llu %@ dl=%+.1fms exp=%+.1fms",
                          t, event.sequence, pad(event.note, 14), event.a, event.b)
        case .submitted:
            return String(format: "%@ sub   seq=%-6llu dw=%.2fms enc=%.2fms dl=%+.1fms exp=%+.1fms",
                          t, event.sequence, event.a, event.b, event.c, event.d)
        case .presented:
            return String(format: "%@ PRES  seq=%-6llu gap=%.1fms age=%.1fms tgt=%+.1fms dw=%.2fms %@",
                          t, event.sequence, event.a, event.b, event.c, event.d, event.note)
        case .unconfirmed:
            return String(format: "%@ PRES? seq=%-6llu presentedTime=0 (+%.1fms)",
                          t, event.sequence, event.a)
        case .rebuilt:
            return String(format: "%@ BUILD %@ conv=%.1fms itp=%.1fms overlay=%.1fms",
                          t, event.note, event.a, event.b, event.c)
        case .hidden:
            return String(format: "%@ HIDE  %@", t, event.note)
        case .shown:
            return String(format: "%@ SHOW  seq=%llu", t, event.sequence)
        case .skipped:
            return String(format: "%@ %@", t, event.note)
        }
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
