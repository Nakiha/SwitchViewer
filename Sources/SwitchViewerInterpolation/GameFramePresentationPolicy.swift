import Foundation

/// Numeric presentation decisions. Access from one executor; no Metal objects,
/// timers or callbacks live here. This initially preserves the v21 policy.
public struct GameFramePresentationPolicy {
    public struct Options {
        public var phaseSlots = false
        public var immediate = false
        public var adaptiveAdmission = false
        public var advanceOriginals = true
        public var correctCadence = false
        public var strictMidpointDeadline = false
        public var legacyPairSubmission = false
        public var minimumCadenceGap = false
        public var preparationAdmission = false
        public init() {}
    }
    public struct Plan {
        public let sequence: UInt64
        public let original: Bool
        public let target: Double
        public let expires: Double
        public let prequeued: Bool
        public let options: Options
        public let lead: Double
        public let advance: Double
        public let phaseDelay: Double
        public var requestLead: Double { lead + advance }
        public var submissionTime: Double { target - requestLead + phaseDelay }
        public var nominalSubmissionTime: Double { target - lead + phaseDelay }
    }
    public struct Context {
        public let active: Bool
        public let generationMatches: Bool
        public let outputReady: Bool
        public let retryAfter: Double
        public let framesAhead: Int
        public init(active: Bool, generationMatches: Bool, outputReady: Bool,
                    retryAfter: Double, framesAhead: Int) {
            self.active = active; self.generationMatches = generationMatches
            self.outputReady = outputReady; self.retryAfter = retryAfter; self.framesAhead = framesAhead
        }
    }
    private var clock = GameFramePresentationClock()
    private var originalClock = GameFramePresentationClock()
    private var unsynced = UnsyncedPresentationPolicy()
    private var cadence = UnsyncedCadenceController()
    private var arbiter = GameFrameSubmissionArbiter()
    private var preparation = GameFramePreparationBudget()
    private var pendingMidpoint: UInt64?
    public private(set) var lastSubmittedSequence: UInt64 = 0
    public var presentationAdvance: Double { clock.advance }
    public var originalPresentationAdvance: Double { originalClock.advance }
    public init() {}

    public mutating func reset(keepingSubmissionOrder: Bool = false) {
        let last = lastSubmittedSequence
        self = Self()
        if keepingSubmissionOrder { lastSubmittedSequence = last }
    }
    public func plan(sequence: UInt64, original: Bool, target: Double, expires: Double,
                     interval: Double, prequeued: Bool, options: Options) -> Plan {
        let lead = prequeued ? GameFramePlayoutPlanner.submissionLead(interval: interval) : 0
        let advance = original && prequeued && options.advanceOriginals ? clock.originalSubmissionAdvance : 0
        let phase = original && options.immediate && options.correctCadence
            ? cadence.submissionDelay(interval: interval, nominal: target - lead, expires: expires) : 0
        return Plan(sequence: sequence, original: original, target: target, expires: expires,
                    prequeued: prequeued, options: options, lead: lead, advance: advance, phaseDelay: phase)
    }
    public func midpointReserve(_ plan: Plan, framesAhead: Int, prepared: Bool = false) -> Double {
        if plan.options.strictMidpointDeadline { return plan.lead }
        if plan.options.immediate && plan.options.preparationAdmission {
            return preparation.reserve(lead: plan.lead, acquired: prepared)
        }
        if plan.options.adaptiveAdmission { return unsynced.midpointReserve(lead: plan.lead, framesAhead: framesAhead) }
        return clock.midpointSubmissionReserve(lead: plan.lead)
    }
    public mutating func recordAcquisition(seconds: Double) { preparation.recordAcquisition(seconds) }
    public mutating func recordEncoding(seconds: Double) { preparation.recordEncoding(seconds) }
    public func requestTime(_ plan: Plan, submittedAt: Double) -> Double {
        if plan.options.immediate { return submittedAt }
        return (plan.original ? originalClock : clock)
            .requestTime(deadline: plan.target, submittedAt: submittedAt, lead: plan.requestLead)
    }
    /// Bound the requested visibility floor inside this frame's remaining slot.
    /// A missing predecessor gets no extra hold. Hardware presentation may still
    /// wait longer than this duration; this is a smoothness/latency tradeoff.
    public func minimumDuration(_ plan: Plan, at now: Double, interval: Double) -> Double {
        guard plan.options.minimumCadenceGap, plan.options.immediate,
              plan.sequence > 0, lastSubmittedSequence == plan.sequence - 1,
              now.isFinite, interval.isFinite, interval > 0 else { return 0 }
        return min(0.003, interval * 0.15, max(0, plan.expires - now - midpointReserve(plan, framesAhead: 0, prepared: true)))
    }
    /// Recheck the same ownership and lifetime rules after asynchronous acquisition.
    public func acquisitionRejection(_ plan: Plan, at now: Double, context: Context) -> FrameStallTrace.Counter? {
        if !context.active { return .dropPaused }
        if !context.generationMatches { return .dropStaleEpoch }
        if plan.sequence <= lastSubmittedSequence { return .dropStaleSequence }
        if !(now < plan.expires) { return .dropExpired }
        if !(now >= context.retryAfter) { return .dropRetryWait }
        return nil
    }
    public func initialRejection(_ plan: Plan, at now: Double, context: Context) -> FrameStallTrace.Counter? {
        if !context.active { return .dropPaused }
        if !context.generationMatches { return .dropStaleEpoch }
        if !context.outputReady { return .dropNotReady }
        if let reason = acquisitionRejection(plan, at: now, context: context) { return reason }
        if !(now - plan.submissionTime < 0.05) { return .dropLate }
        return finalRejection(plan, at: now, framesAhead: context.framesAhead)
    }
    public func finalRejection(_ plan: Plan, at now: Double, framesAhead: Int, prepared: Bool = false) -> FrameStallTrace.Counter? {
        if !(now < plan.expires && (plan.original || now + midpointReserve(plan, framesAhead: framesAhead, prepared: prepared) < plan.expires)) {
            return .dropPastExpiry
        }
        return nil
    }
    public mutating func submitted(_ sequence: UInt64) { lastSubmittedSequence = sequence }
    public mutating func presented(_ plan: Plan, submittedAt: Double, requestedAt: Double,
                                  presentedAt: Double, framesAhead: Int) {
        if plan.options.immediate && plan.options.correctCadence {
            cadence.record(sequence: plan.sequence, presentedAt: presentedAt)
        }
        if plan.options.adaptiveAdmission && !plan.original {
            unsynced.recordMidpoint(submittedAt: submittedAt, presentedAt: presentedAt, framesAhead: framesAhead)
        }
        if plan.prequeued {
            if plan.original {
                clock.recordOriginal(deadline: plan.target, presentedAt: presentedAt)
                originalClock.record(requestedAt: requestedAt, presentedAt: presentedAt, lead: plan.requestLead)
            } else {
                clock.record(requestedAt: requestedAt, presentedAt: presentedAt, lead: plan.lead)
            }
        }
    }
    public mutating func beginMidpoint(_ sequence: UInt64) { pendingMidpoint = sequence }
    public mutating func readyMidpoint(_ sequence: UInt64) { arbiter.registerMidpoint(sequence) }
    public mutating func resolveMidpoint(_ sequence: UInt64) {
        arbiter.resolveMidpoint(sequence)
        if pendingMidpoint == sequence { pendingMidpoint = nil }
    }
    public func originalWaitUntil(_ plan: Plan, at now: Double) -> Double? {
        if plan.options.phaseSlots { return nil }
        if plan.options.legacyPairSubmission {
            return plan.sequence > 0 && pendingMidpoint == plan.sequence - 1 && now < plan.nominalSubmissionTime
                ? plan.nominalSubmissionTime : nil
        }
        return arbiter.originalWaitUntil(sequence: plan.sequence, pendingMidpoint: pendingMidpoint,
                                        nominal: plan.nominalSubmissionTime, expires: plan.expires, now: now)
    }
}
