import XCTest
@testable import SwitchViewerInterpolation

final class FrameStallTraceTests: XCTestCase {
    func testCaptureGapProducesRewindReportWithSurroundingFrames() {
        let trace = FrameStallTrace(captureGapThreshold: 0.080, reportCooldown: 0)
        for index in 0..<5 {
            trace.noteCaptured(time: Double(index) * 0.033, width: 3024, height: 1898)
        }
        // 游戏侧停顿 200ms。
        trace.noteCaptured(time: 4 * 0.033 + 0.200, width: 3024, height: 1898)
        let reports = trace.takeStallReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].kind, "captureGap")
        XCTAssertEqual(reports[0].gapMilliseconds, 200, accuracy: 0.001)
        // 倒带必须包含停顿前后的事件，而不只是停顿本身。
        XCTAssertEqual(reports[0].lines.count, 6)
        XCTAssertTrue(reports[0].lines.first!.contains("cap"))
        XCTAssertTrue(reports[0].lines.last!.contains("gap=200.0ms"))
        XCTAssertTrue(trace.takeStallReports().isEmpty, "报告只能取走一次")
    }

    func testPresentationGapSeparatesNotSubmittedFromNotDisplayed() {
        let trace = FrameStallTrace(presentationGapThreshold: 0.060, reportCooldown: 0)
        // 正常两帧。
        trace.noteSubmitted(time: 0.000, sequence: 1, deadline: 0.010, expires: 0.030,
                            drawableWaitMilliseconds: 0.02, encodeMilliseconds: 1.0)
        trace.notePresented(time: 0.020, sequence: 1, sourceTime: 0.000, submitTime: 0.000,
                            deadline: 0.010, drawableWaitMilliseconds: 0.02, encodeMilliseconds: 1.0)
        // 之后 150ms 里提交了 4 帧，一帧都没上屏 —— 这是"提交了没上屏"。
        for index in 0..<4 {
            let time = 0.040 + Double(index) * 0.025
            trace.noteSubmitted(time: time, sequence: UInt64(2 + index),
                                deadline: time, expires: time + 0.020,
                                drawableWaitMilliseconds: 0.02, encodeMilliseconds: 1.0)
        }
        trace.notePresented(time: 0.170, sequence: 6, sourceTime: 0.150, submitTime: 0.165,
                            deadline: 0.160, drawableWaitMilliseconds: 0.02, encodeMilliseconds: 1.0)
        let reports = trace.takeStallReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].kind, "presentationGap")
        XCTAssertEqual(reports[0].gapMilliseconds, 150, accuracy: 0.001)
        XCTAssertEqual(reports[0].lines.filter { $0.contains("sub") }.count, 5)
        let window = trace.takeWindow()
        XCTAssertEqual(window.presentationGapMaxMilliseconds, 150, accuracy: 0.001)
        XCTAssertEqual(window.presentationGapCount, 1)
        XCTAssertEqual(window.submittedTotal, 5)
        XCTAssertEqual(window.presentedTotal, 2)
        XCTAssertEqual(window.pendingSubmissions, 3, "3 帧提交后始终没有上屏回调")
    }

    func testUnconfirmedPresentationsAreCountedSeparately() {
        let trace = FrameStallTrace()
        trace.noteSubmitted(time: 1.0, sequence: 1, deadline: 1.0, expires: 1.02,
                            drawableWaitMilliseconds: 0.0, encodeMilliseconds: 0.5)
        trace.noteUnconfirmed(time: 1.05, sequence: 1, submitTime: 1.0)
        let window = trace.takeWindow()
        XCTAssertEqual(window.counters.first { $0.label == "presentTime0" }?.count, 1)
        XCTAssertEqual(window.presentedTotal, 0)
        // 回调到了、drawable 已回收，所以 pending 只统计"完全没有回调"的那种。
        XCTAssertEqual(window.pendingSubmissions, 0)
    }

    func testWindowCountersAreDeltasAndDropReasonsAreNamed() {
        let trace = FrameStallTrace()
        trace.count(.dropLate)
        trace.count(.dropLate)
        trace.count(.dropNoDrawable)
        let first = trace.takeWindow()
        XCTAssertEqual(first.counters.first { $0.label == "dropLate" }?.count, 2)
        XCTAssertEqual(first.counters.first { $0.label == "dropNoDrawable" }?.count, 1)
        // 第二窗口应为空增量，累计值仍然保留。
        XCTAssertTrue(trace.takeWindow().counters.isEmpty)
        let summary = trace.counterSummary()
        XCTAssertEqual(summary.first { $0.label == "dropLate" }?.count, 2)
        XCTAssertEqual(summary.first { $0.label == "dropNoDrawable" }?.count, 1)
    }

    func testDroppedAndSubmittedEventsKeepSequenceForOrderingChecks() {
        let trace = FrameStallTrace(reportCooldown: 0)
        trace.notePlanned(time: 0.0, sequence: 7, deadline: 0.030, expires: 0.055, prequeued: true)
        trace.noteDropped(time: 0.001, sequence: 7, reason: .dropLate, deadline: 0.030, expires: 0.055)
        trace.noteSubmitted(time: 0.002, sequence: 8, deadline: 0.032, expires: 0.057,
                            drawableWaitMilliseconds: 0.01, encodeMilliseconds: 0.8)
        // 用一次采集停顿触发倒带，检查事件文本。
        trace.noteCaptured(time: 0.0, width: 1920, height: 1080)
        trace.noteCaptured(time: 0.500, width: 1920, height: 1080)
        let lines = trace.takeStallReports().first?.lines ?? []
        XCTAssertTrue(lines.contains { $0.contains("seq=7") && $0.contains("dropLate") })
        XCTAssertTrue(lines.contains { $0.contains("sub") && $0.contains("seq=8") })
    }

    func testReportCooldownSuppressesRepeatedStalls() {
        let trace = FrameStallTrace(presentationGapThreshold: 0.060, reportCooldown: 2.0)
        func present(_ time: Double) {
            trace.notePresented(time: time, sequence: 1, sourceTime: time - 0.05, submitTime: time - 0.01,
                                deadline: time, drawableWaitMilliseconds: 0, encodeMilliseconds: 0)
        }
        present(0.0)
        present(0.100)   // 停顿 1，报告
        present(0.200)   // 同一轮，冷却中，不报告
        XCTAssertEqual(trace.takeStallReports().count, 1)
        present(2.500)   // 仍是同一轮，但冷却已过
        XCTAssertEqual(trace.takeStallReports().count, 1)
    }

    func testStallEpisodeCapsDumpsAndRestartsAfterRecovery() {
        let trace = FrameStallTrace(presentationGapThreshold: 0.060, reportCooldown: 0,
                                    maxDumpsPerEpisode: 2)
        func present(_ time: Double) {
            trace.notePresented(time: time, sequence: 1, sourceTime: time - 0.05, submitTime: time - 0.01,
                                deadline: time, drawableWaitMilliseconds: 0, encodeMilliseconds: 0)
        }
        present(0.0)
        // 一次几分钟的中断会持续产生停顿，同一轮只倒带 2 次。
        for index in 1...5 { present(Double(index) * 0.200) }
        XCTAssertEqual(trace.takeStallReports().count, 2)
        // 一次正常间隔代表本轮结束，下一轮重新给额度。
        let resume = 5 * 0.200 + 0.016
        present(resume)
        for index in 1...5 { present(resume + Double(index) * 0.200) }
        XCTAssertEqual(trace.takeStallReports().count, 2, "新一轮重新计数")
    }

    func testRingBufferKeepsMostRecentEventsAndBoundedReports() {
        let trace = FrameStallTrace(capacity: 16, captureGapThreshold: 0.080, reportCooldown: 0)
        for index in 0..<40 {
            trace.noteCaptured(time: Double(index) * 0.010, width: 1920, height: 1080)
        }
        trace.noteCaptured(time: 1.000, width: 1920, height: 1080)
        let reports = trace.takeStallReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].lines.count, 16, "容量被尊重")
        // 最早的 40 帧里有 24 帧已经被覆盖，倒带只能看到最近 16 条。
        XCTAssertTrue(reports[0].lines.first!.contains("gap=10.0ms"))
    }

    func testLongStallRewindKeepsTriggerAndRecoveryOnly() {
        let trace = FrameStallTrace(capacity: 4096, presentationGapThreshold: 0.060,
                                    reportCooldown: 0, rewindHeadLines: 10,
                                    rewindTailLines: 5, rewindPreContext: 2)
        trace.notePresented(time: 0.0, sequence: 0, sourceTime: 0, submitTime: 0,
                            deadline: 0, drawableWaitMilliseconds: 0, encodeMilliseconds: 0)
        // 停顿期间丢了 500 帧：全量倒带会淹掉日志。
        for index in 0..<500 {
            trace.noteDropped(time: 0.100 + Double(index) * 0.010, sequence: UInt64(index),
                              reason: .dropRetryWait, deadline: 0, expires: 0)
        }
        trace.notePresented(time: 6.0, sequence: 999, sourceTime: 5.9, submitTime: 5.95,
                            deadline: 6.0, drawableWaitMilliseconds: 0, encodeMilliseconds: 0)
        let lines = trace.takeStallReports().first?.lines ?? []
        // 触发点之后 10 条 + 省略行 + 恢复前 5 条（停顿前的 2 条上下文已经在缓冲最前面）。
        XCTAssertEqual(lines.count, 10 + 1 + 5)
        XCTAssertTrue(lines.contains { $0.contains("省略 487 条") })
        XCTAssertTrue(lines.first!.contains("PRES"), "倒带要包含停顿前最后一次上屏")
        XCTAssertTrue(lines.last!.contains("gap=6000.0ms"), "倒带要包含恢复的那一帧")
    }

    func testSilenceProbeCatchesOutageWithNoPresentationAtAll() {
        let trace = FrameStallTrace(presentationSilenceThreshold: 0.5, reportCooldown: 0,
                                    maxDumpsPerEpisode: 2)
        trace.notePresented(time: 0.0, sequence: 1, sourceTime: 0, submitTime: 0,
                            deadline: 0, drawableWaitMilliseconds: 0, encodeMilliseconds: 0)
        // 之后显示路径彻底停摆：只有丢弃，没有上屏。
        for index in 0..<40 {
            trace.noteDropped(time: 0.1 + Double(index) * 0.1, sequence: UInt64(index + 2),
                              reason: .dropRetryWait, deadline: 0, expires: 0)
        }
        for tick in 1...30 { trace.probe(time: Double(tick) * 0.1) }
        let reports = trace.takeStallReports()
        XCTAssertEqual(reports.count, 2, "同一轮静默最多倒带 2 次")
        XCTAssertEqual(reports[0].kind, "noPresentation")
        XCTAssertTrue(reports[0].lines.contains { $0.contains("dropRetryWait") })
        let window = trace.takeWindow()
        XCTAssertEqual(window.presentationGapMaxMilliseconds, 3000, accuracy: 0.001,
                       "静默时长要计入窗口最大值")
        // 恢复一帧后本轮结束；这一帧本身间隔 3.1s，会记为一次上屏间隔停顿。
        trace.notePresented(time: 3.1, sequence: 99, sourceTime: 3.0, submitTime: 3.0,
                            deadline: 3.0, drawableWaitMilliseconds: 0, encodeMilliseconds: 0)
        let recovery = trace.takeStallReports()
        XCTAssertEqual(recovery.count, 1)
        XCTAssertEqual(recovery[0].kind, "presentationGap")
        for tick in 1...30 { trace.probe(time: 3.1 + Double(tick) * 0.1) }
        XCTAssertEqual(trace.takeStallReports().count, 2, "新一轮静默重新给 2 次额度")
    }

    func testRebuildEventCarriesStageCosts() {
        let trace = FrameStallTrace(captureGapThreshold: 10, reportCooldown: 0)
        trace.noteCaptured(time: 0.0, width: 3024, height: 1898)
        trace.noteRebuilt(time: 0.010, from: "3024x1898", to: "3024x1764",
                          converterMilliseconds: 42.0, interpolatorMilliseconds: 180.0,
                          overlayMilliseconds: 3.0)
        trace.noteCaptured(time: 0.011, width: 3024, height: 1764)
        let window = trace.takeWindow()
        XCTAssertEqual(window.captureGapCount, 0, "阈值内的重建不应该被算成停顿")
        XCTAssertEqual(window.captureGapMaxMilliseconds, 11, accuracy: 0.001)
    }
}
