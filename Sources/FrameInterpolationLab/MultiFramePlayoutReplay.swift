import Foundation
import SwitchViewerInterpolation

private func replayQuantile(_ values: [Double], _ q: Double) -> Double {
    let sorted = values.sorted()
    return sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * q)) - 1))]
}
/// Deadline admission only. It intentionally does not claim physical presentation
/// or exercise the production pair-specific ownership/sequence numbering.
func runMultiFramePlayoutReplay(inputPath: String, outputPath: String) throws {
    let source = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: inputPath))) as! [String: Any]
    let runs = source["runs"] as! [[String: Any]]
    var rows: [[String: Any]] = []
    for width in [1920,1280] {
        let baseline = runs.first { ($0["width"] as? Int) == width && ($0["level"] as? Int) == 1 && ($0["delivery"] as? String) == "batch" }!
        let baseSamples = baseline["samples"] as! [[String: Any]]
        for fps in [30.0,45.0,60.0] {
            let interval = 1 / fps
            var pressure = GameFramePressureController()
            var baselineDelay = interval * 1.25
            // Bring the current pressure controller to a stable baseline first.
            for n in 0..<240 {
                pressure.recordProcessing(seconds: (baseSamples[n % baseSamples.count]["totalMS"] as! Double) / 1000)
                pressure.recordDelivery(shown: true)
                baselineDelay = pressure.delay(interval: interval)!
            }
            for run in runs where (run["width"] as? Int) == width && (run["phases"] as? [Double])?.count != 1 {
                let samples = run["samples"] as! [[String: Any]]
                guard !samples.isEmpty else { continue }
                let phases = run["phases"] as! [Double], multiplier = Double(phases.count + 1)
                for overheadMS in [2.0,8.0] {
                    let policy = GameFramePresentationPolicy()
                    var options = GameFramePresentationPolicy.Options()
                    options.immediate = true; options.adaptiveAdmission = true; options.preparationAdmission = true; options.minimumCadenceGap = true
                    var required: [Double] = [], accepted = 0, nominal = 0, frames = 0
                    for sample in samples {
                        let outputs = sample["outputs"] as! [[String: Any]]
                        var needed = 0.0
                        for output in outputs {
                            let phase = output["phase"] as! Double, ready = interval + ((output["readyMS"] as! Double) + overheadMS) / 1000
                            // Use each generated frame's own slot, rather than allowing
                            // every phase to overwrite the full original-to-original interval.
                            let target = baselineDelay + interval * phase
                            let expires = baselineDelay + interval * (phase + 1 / multiplier)
                            let plan = policy.plan(sequence: UInt64(frames + 1), original: false, target: target,
                                expires: expires, interval: interval, prequeued: true, options: options)
                            let reserve = policy.midpointReserve(plan, framesAhead: 0)
                            needed = max(needed, ready + reserve - interval * phase)
                            let context = GameFramePresentationPolicy.Context(active: true,generationMatches: true,outputReady: true,retryAfter: 0,framesAhead: 0)
                            if policy.initialRejection(plan, at: max(ready, plan.submissionTime), context: context) == nil { accepted += 1 }
                            if ready + reserve <= target { nominal += 1 }
                            frames += 1
                        }
                        required.append(needed * 1000)
                    }
                    let minDelay95 = replayQuantile(required,0.95)
                    let total = samples.map { $0["totalMS"] as! Double }
                    rows.append(["width":width,"inputFPS":fps,"multiplier":Int(multiplier),"delivery":run["delivery"]!,
                        "modeledPipelineOverheadMS":overheadMS,"reserveMS":GameFramePreparationBudget().reserve(lead:GameFramePlayoutPlanner.submissionLead(interval:interval),acquired:false)*1000,
                        "currentTwoXDelayMS":baselineDelay*1000,"requiredDelayP50MS":replayQuantile(required,0.5),"requiredDelayP95MS":minDelay95,
                        "extraDelayP95MS":max(0,minDelay95-baselineDelay*1000),"framesAdmittedByCurrentPolicyFraction":Double(accepted)/Double(frames),
                        "nominalDeadlineMetFraction":Double(nominal)/Double(frames),"processingFitsInputIntervalFraction":Double(total.filter{$0+overheadMS<interval*1000}.count)/Double(total.count),
                        "outputFPS":fps*multiplier,"currentPrequeuePathSupported":GameFramePlayoutPlanner.supportsPrequeue(interval:interval)])
                }
            }
        }
    }
    let result: [String:Any] = ["source":URL(fileURLWithPath:inputPath).lastPathComponent,"rows":rows,
        "model":"Uses actual GameFramePressureController and GameFramePresentationPolicy initialRejection; ideal single-job decoded input, empty drawable queue, uniform unsynced preparation admission. Assumes 2 or 8 ms conversion/dispatch overhead; does not model actual GPU contention, display callbacks or WindowServer queue. The 60fps rows are timing arithmetic only: production prequeue path supports input at <=50fps. Pair ownership and sequence numbering still require N-slot implementation."]
    try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:outputPath))
    print("REPLAY \(outputPath)")
}
