import CoreVideo
import Foundation

/// Detects game content that updates at half the capture cadence, even when a
/// smaller part of the composite image (such as a console UI overlay) changes
/// on every captured frame.
public final class SwitchFrameCadenceDetector {
    public struct Result {
        public let captureFPS: Double?
        public let gameFPS: Double?
        public let confidence: Double
        public let cadencePeriod: Int?
        public let repeatedGameFrame: Bool
        public let repeatedMotionCoverage: Double
        public let dynamicSampleCount: Int
        /// Mean absolute luma change across the 128x72 sample, normalized to 0...1.
        public let frameDifferenceScore: Double

        /// Wait for a stable cadence first; once detected, skip only intervals
        /// where the game content is a repeat. Unknown or native-rate content
        /// continues through the normal interpolator after warm-up.
        public var shouldInterpolate: Bool {
            guard captureFPS != nil else { return false }
            return gameFPS == nil || !repeatedGameFrame
        }
    }

    private struct Interval {
        let seconds: Double
        let difference: [UInt8]
    }

    private let sampleWidth = 128
    private let sampleHeight = 72
    // Twelve capture intervals hold six 30fps cycles or four 40fps cycles at 60Hz.
    private let historyLength = 12
    private let lowMotionThreshold = 1.5
    private let highMotionThreshold = 3.0
    private let minimumConfidence = 0.68
    private let minimumCoverage = 0.002
    private var previousSamples: [UInt8]?
    private var previousTime: Double?
    private var intervals: [Interval] = []

    public init() {}

    public func reset() {
        previousSamples = nil
        previousTime = nil
        intervals.removeAll(keepingCapacity: true)
    }

    /// Call once for each captured frame, in presentation-time order.
    public func observe(_ pixelBuffer: CVPixelBuffer, presentationTime: Double) -> Result {
        let samples = sampleLuma(pixelBuffer)
        defer {
            previousSamples = samples
            previousTime = presentationTime
        }
        guard let previousSamples, let previousTime else { return unknown() }
        let interval = presentationTime - previousTime
        guard interval > 0, interval < 0.25, samples.count == previousSamples.count else {
            intervals.removeAll(keepingCapacity: true)
            return unknown()
        }
        let differences = zip(samples, previousSamples).map { UInt8(abs(Int($0) - Int($1))) }
        let frameDifferenceScore = Double(differences.reduce(0) { $0 + Int($1) })
            / Double(max(1, differences.count)) / 255.0
        intervals.append(Interval(seconds: interval, difference: differences))
        if intervals.count > historyLength {
            intervals.removeFirst(intervals.count - historyLength)
        }
        guard intervals.count == historyLength else { return unknown(frameDifferenceScore: frameDifferenceScore) }

        struct Candidate {
            let period: Int
            let repeatPhase: Int
            let detectedCount: Int
            let dynamicCount: Int
            let latestRepeatCount: Int
        }
        var candidates: [Candidate] = []
        for period in [2, 3] {
            var detectedByPhase = [Int](repeating: 0, count: period)
            var latestRepeatByPhase = [Int](repeating: 0, count: period)
            var dynamicCount = 0
            for index in 0..<samples.count {
                var means = [Double](repeating: 0, count: period)
                var counts = [Int](repeating: 0, count: period)
                for intervalIndex in intervals.indices {
                    let phase = intervalIndex % period
                    means[phase] += Double(intervals[intervalIndex].difference[index])
                    counts[phase] += 1
                }
                for phase in 0..<period {
                    means[phase] /= Double(counts[phase])
                }
                let maxMotion = means.max() ?? 0
                if maxMotion >= highMotionThreshold { dynamicCount += 1 }
                guard let repeatPhase = means.indices.min(by: { means[$0] < means[$1] }),
                      means[repeatPhase] <= lowMotionThreshold else { continue }
                let changedPhases = means.indices.filter { $0 != repeatPhase }
                guard changedPhases.allSatisfy({ means[$0] >= highMotionThreshold }) else { continue }
                detectedByPhase[repeatPhase] += 1
                if Double(intervals[historyLength - 1].difference[index]) <= lowMotionThreshold {
                    latestRepeatByPhase[repeatPhase] += 1
                }
            }
            guard let phase = detectedByPhase.indices.max(by: {
                detectedByPhase[$0] < detectedByPhase[$1]
            }) else { continue }
            candidates.append(Candidate(period: period, repeatPhase: phase,
                                        detectedCount: detectedByPhase[phase],
                                        dynamicCount: dynamicCount,
                                        latestRepeatCount: latestRepeatByPhase[phase]))
        }
        guard let candidate = candidates.max(by: {
            $0.detectedCount < $1.detectedCount
        }) else { return unknown(frameDifferenceScore: frameDifferenceScore) }
        let detectedCount = candidate.detectedCount
        let dynamicCount = candidate.dynamicCount
        let confidence = dynamicCount == 0 ? 0 : Double(detectedCount) / Double(dynamicCount)
        let coverage = Double(detectedCount) / Double(samples.count)
        let medianInterval = intervals.map(\.seconds).sorted()[historyLength / 2]
        let captureFPS = 1.0 / medianInterval
        let stableCaptureCadence = intervals.allSatisfy {
            abs($0.seconds - medianInterval) / medianInterval < 0.12
        }
        let detected = stableCaptureCadence
            && detectedCount >= 8
            && confidence >= minimumConfidence
            && coverage >= minimumCoverage
        let latestIntervalRepeatsGame = (historyLength - 1) % candidate.period == candidate.repeatPhase
            && candidate.latestRepeatCount > detectedCount / 2
        return Result(captureFPS: captureFPS,
                      gameFPS: detected
                        ? captureFPS * Double(candidate.period - 1) / Double(candidate.period) : nil,
                      confidence: detected ? confidence : 0,
                      cadencePeriod: detected ? candidate.period : nil,
                      repeatedGameFrame: detected && latestIntervalRepeatsGame,
                      repeatedMotionCoverage: detected ? coverage : 0,
                      dynamicSampleCount: dynamicCount,
                      frameDifferenceScore: frameDifferenceScore)
    }

    private func unknown(frameDifferenceScore: Double = 0) -> Result {
        Result(captureFPS: nil, gameFPS: nil, confidence: 0,
               cadencePeriod: nil, repeatedGameFrame: false,
               repeatedMotionCoverage: 0, dynamicSampleCount: 0,
               frameDifferenceScore: frameDifferenceScore)
    }

    private func sampleLuma(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            return []
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return [] }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var result = [UInt8](repeating: 0, count: sampleWidth * sampleHeight)
        for y in 0..<sampleHeight {
            let sourceY = min(height - 1, (2 * y + 1) * height / (2 * sampleHeight))
            let row = pixels.advanced(by: sourceY * stride)
            for x in 0..<sampleWidth {
                let sourceX = min(width - 1, (2 * x + 1) * width / (2 * sampleWidth))
                result[y * sampleWidth + x] = row[sourceX]
            }
        }
        return result
    }
}
