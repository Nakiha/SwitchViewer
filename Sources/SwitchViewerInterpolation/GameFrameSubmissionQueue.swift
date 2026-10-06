import Foundation

/// Runs on the presentation executor. The executor supplies the clock and task
/// dispatch so pair ownership/reset can be tested without a game or real timers.
public final class GameFrameSubmissionQueue {
    public typealias Task = () -> Void
    public typealias Schedule = (Double, @escaping Task) -> Void
    public struct Hold {
        public let sequence: UInt64
        public let time: Double
        public let nominal: Double
        public let until: Double
    }
    public var policy = GameFramePresentationPolicy()
    private let now: () -> Double
    private let schedule: Schedule
    private let deferTask: (@escaping Task) -> Void
    /// Also guards acquisition and presentation callbacks that outlive a reset.
    public private(set) var generation: UInt64 = 0
    private var ready: [UInt64: Task] = [:]
    private var waiting: [UInt64: Task] = [:]
    public init(now: @escaping () -> Double, schedule: @escaping Schedule,
                deferTask: @escaping (@escaping Task) -> Void) {
        self.now = now; self.schedule = schedule; self.deferTask = deferTask
    }
    public func reset(keepingSubmissionOrder: Bool = false) {
        generation &+= 1
        ready.removeAll(); waiting.removeAll()
        policy.reset(keepingSubmissionOrder: keepingSubmissionOrder)
    }
    public func resolveMidpoint(_ sequence: UInt64) {
        policy.resolveMidpoint(sequence)
        ready.removeValue(forKey: sequence)
        if let wake = waiting.removeValue(forKey: sequence + 1) {
            let revision = generation
            // Complete the current midpoint commit/drop before waking its original.
            deferTask { [self] in guard generation == revision else { return }; wake() }
        }
    }
    public func enqueue(_ plan: GameFramePresentationPolicy.Plan, submit: @escaping Task,
                        onHold: @escaping (Hold) -> Void) {
        let revision = generation
        if !plan.original {
            policy.readyMidpoint(plan.sequence)
            ready[plan.sequence] = submit
        }
        schedule(plan.submissionTime) { [self] in
            guard generation == revision else { return }
            if plan.original { submitOriginal(plan, revision: revision, submit: submit, onHold: onHold) }
            else { startMidpoint(plan.sequence) }
        }
    }
    private func startMidpoint(_ sequence: UInt64) { ready.removeValue(forKey: sequence)?() }
    private func submitOriginal(_ plan: GameFramePresentationPolicy.Plan, revision: UInt64,
                                submit: @escaping Task, onHold: @escaping (Hold) -> Void) {
        guard generation == revision else { return }
        if !plan.options.phaseSlots, !plan.options.legacyPairSubmission, plan.sequence > 0 { startMidpoint(plan.sequence - 1) }
        let time = now()
        if let until = policy.originalWaitUntil(plan, at: time) {
            onHold(Hold(sequence: plan.sequence, time: time, nominal: plan.nominalSubmissionTime, until: until))
            guard waiting[plan.sequence] == nil else { return }
            waiting[plan.sequence] = { [self] in submitOriginal(plan, revision: revision, submit: submit, onHold: onHold) }
            schedule(until) { [self] in
                guard generation == revision else { return }
                waiting.removeValue(forKey: plan.sequence)?()
            }
        } else {
            waiting.removeValue(forKey: plan.sequence)
            submit()
        }
    }
}
