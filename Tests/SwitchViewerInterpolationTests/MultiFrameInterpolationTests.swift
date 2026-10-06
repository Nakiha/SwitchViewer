import CoreMedia
import CoreVideo
import XCTest
@testable import SwitchViewerInterpolation

final class MultiFrameInterpolationTests: XCTestCase {
    func testBudgetPersistsZeroAndDefaultIndependentlyOfMultiplier() throws {
        let name = "SwitchViewerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(InterpolationOptions.load(defaults: defaults, prefix: "capture").usesLegacyTiming)
        let selected = InterpolationOptions(multiplier: .eight, delayBudgetMilliseconds: 0)
        selected.save(defaults: defaults, prefix: "capture")
        XCTAssertEqual(InterpolationOptions.load(defaults: defaults, prefix: "capture"), selected)
        XCTAssertTrue(InterpolationOptions.load(defaults: defaults, prefix: "game").usesLegacyTiming)
        InterpolationOptions().save(defaults: defaults, prefix: "capture")
        XCTAssertTrue(InterpolationOptions.load(defaults: defaults, prefix: "capture").usesLegacyTiming)
        XCTAssertNil(InterpolationOptions(delayBudgetMilliseconds: .nan).delayBudgetMilliseconds)
        XCTAssertEqual(InterpolationOptions(delayBudgetMilliseconds: 999).delayBudgetMilliseconds, 250)
    }

    func testOverloadedProcessorCannotRaiseUserBudgetOrLowerSelectedMultiplier() {
        var controller = MultiFrameDelayController()
        let selected = InterpolationOptions(multiplier: .eight, delayBudgetMilliseconds: 20)
        for _ in 0..<300 {
            for phase in selected.multiplier.phases {
                controller.record(phase: phase, interval: 1 / 30, readySeconds: 0.150)
            }
            XCTAssertEqual(controller.delay(interval: 1 / 30, options: selected), 0.020, accuracy: 0.000001)
        }
        XCTAssertEqual(selected.multiplier, .eight)
        XCTAssertEqual(controller.delay(interval: 1 / 30, options: .init(multiplier: .four, delayBudgetMilliseconds: 0)), 0)
        controller.reset()
        XCTAssertLessThan(controller.delay(interval: 1 / 30, options: .init(multiplier: .four)), 0.050)
    }

    func testEarlyPhaseReadinessNeedsMoreLookaheadAndSlowSamplesAreNotClipped() {
        var early = MultiFrameDelayController(), late = MultiFrameDelayController()
        for _ in 0..<20 {
            early.record(phase: 0.25, interval: 0.040, readySeconds: 0.110)
            late.record(phase: 0.75, interval: 0.040, readySeconds: 0.110)
        }
        let options = InterpolationOptions(multiplier: .four, delayBudgetMilliseconds: 250)
        XCTAssertEqual(early.delay(interval: 0.040, options: options), 0.144, accuracy: 0.000001)
        XCTAssertEqual(late.delay(interval: 0.040, options: options), 0.124, accuracy: 0.000001)
    }

    func testMultiPhaseQueueNeverPumpsFuturePhaseOrHoldsOriginalAndResetCancelsOldGroup() {
        var tasks: [(Double, () -> Void)] = []
        var now = 0.0, submitted: [UInt64] = []
        let queue = GameFrameSubmissionQueue(now: { now }, schedule: { tasks.append(($0, $1)) }, deferTask: { tasks.append((now, $0)) })
        var options = GameFramePresentationPolicy.Options()
        options.phaseSlots = true
        func enqueue(_ sequence: UInt64, original: Bool, time: Double) {
            let plan = queue.policy.plan(sequence: sequence, original: original, target: time,
                expires: time + 0.008, interval: 0.008, prequeued: false, options: options)
            queue.enqueue(plan, submit: { submitted.append(sequence) }, onHold: { _ in XCTFail("Phase groups cannot hold originals") })
        }
        // Output callback order differs from media order.
        enqueue(7, original: false, time: 1.040)
        enqueue(5, original: false, time: 1.010)
        enqueue(6, original: false, time: 1.020)
        enqueue(8, original: true, time: 1.030)
        queue.policy.beginMidpoint(7)
        queue.policy.readyMidpoint(7)
        while let index = tasks.indices.min(by: { tasks[$0].0 < tasks[$1].0 }), tasks[index].0 <= 1.030 {
            let task = tasks.remove(at: index); now = task.0; task.1()
        }
        XCTAssertEqual(submitted, [5, 6, 8])
        queue.reset()
        for task in tasks { now = task.0; task.1() }
        XCTAssertEqual(submitted, [5, 6, 8])
    }

    func testExpiredPhaseCannotOverwriteNewerOriginal() {
        var policy = GameFramePresentationPolicy()
        var options = GameFramePresentationPolicy.Options(); options.phaseSlots = true
        let plan = policy.plan(sequence: 5, original: false, target: 1.010, expires: 1.020,
                               interval: 0.010, prequeued: false, options: options)
        let context = GameFramePresentationPolicy.Context(active: true, generationMatches: true,
            outputReady: true, retryAfter: 0, framesAhead: 0)
        XCTAssertEqual(policy.initialRejection(plan, at: 1.021, context: context), .dropExpired)
        policy.submitted(8)
        XCTAssertEqual(policy.acquisitionRejection(plan, at: 1.015, context: context), .dropStaleSequence)
    }

    func testRealProcessorProducesEveryRequestedPhaseAndSurvivesOwnerRelease() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires Apple interpolation") }
        try HardwareTestSupport.requireAppleInterpolation()
        for multiplier in InterpolationMultiplier.allCases {
            var interpolator: AppleDownsampledFrameInterpolator? = try AppleDownsampledFrameInterpolator(
                width: 1280, height: 720, multiplier: multiplier)
            weak var released = interpolator
            let a = try frame(value: 60), b = try frame(value: 120)
            let done = expectation(description: "\(multiplier.label) outputs complete")
            let lock = NSLock(); var phases: [Double] = []
            try interpolator!.submitFrames(previous: a, current: b,
                previousPresentationTimeStamp: CMTime(value: 1, timescale: 30),
                currentPresentationTimeStamp: CMTime(value: 2, timescale: 30),
                onFrame: { buffer, phase, milliseconds in
                    XCTAssertGreaterThan(milliseconds, 0)
                    XCTAssertEqual(CVPixelBufferGetWidth(buffer), 1280)
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let first = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.load(as: UInt8.self)
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    XCTAssertGreaterThan(first, 1)
                    lock.lock(); phases.append(phase); lock.unlock()
                }, completion: { result, error in
                    XCTAssertNil(error); XCTAssertNotNil(result)
                    lock.lock(); let observed = phases.sorted(); lock.unlock()
                    XCTAssertEqual(observed, multiplier.phases)
                    done.fulfill()
                })
            interpolator = nil
            wait(for: [done], timeout: 10)
            let destroyed = expectation(description: "session released")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                XCTAssertNil(released); FrameProcessorSessionCleanup.queue.sync {}; destroyed.fulfill()
            }
            wait(for: [destroyed], timeout: 10)
        }
    }

    private func frame(value: Int32) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(pb, plane)!, plane == 0 ? value : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(pb, plane) * CVPixelBufferGetHeightOfPlane(pb, plane))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
