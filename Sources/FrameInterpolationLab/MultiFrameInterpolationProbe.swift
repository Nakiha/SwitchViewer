import Foundation
import AVFoundation
import VideoToolbox
import CoreImage
import Metal
import QuartzCore
import SwitchViewerInterpolation
import AppKit

private struct ProbeFrame { let buffer: CVPixelBuffer; let time: Double }
private struct ProbeOutput: Codable { let phase: Double; let readyMS: Double; let meanLuma: Double }
private struct ProbeSample: Codable { let totalMS: Double; let outputs: [ProbeOutput] }
private struct ProbeRun: Codable {
    let width: Int; let height: Int; let level: Int; let phases: [Double]; let delivery: String
    let setupMS: Double; let warmupMS: [Double]; let samples: [ProbeSample]; let error: String?
}
private final class ProbeResult: @unchecked Sendable {
    var outputs: [(Double, Double)] = []; var error: Error?
    let done = DispatchSemaphore(value: 0)
}
private func probeBuffer(width: Int, height: Int, attributes: [String: Any]) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes as CFDictionary, &buffer)
    guard status == kCVReturnSuccess, let buffer else { throw NSError(domain: "MultiFrameProbe", code: Int(status)) }
    return buffer
}
private func probeLuma(_ buffer: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
    let pixels = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    var sum = 0.0, count = 0.0
    for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 16) {
        for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 16) { sum += Double(pixels[y * stride + x]); count += 1 }
    }
    return sum / max(1, count)
}
private func probeFrames(_ path: String, count: Int) throws -> [ProbeFrame] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else { throw NSError(domain: "MultiFrameProbe.NoVideo", code: 1) }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
    output.alwaysCopiesSampleData = false; reader.add(output)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "MultiFrameProbe.Reader", code: 1) }
    var frames: [ProbeFrame] = []
    while frames.count < count, let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
        frames.append(ProbeFrame(buffer: buffer, time: CMTimeGetSeconds(CMSampleBufferGetOutputPresentationTimeStamp(sample))))
    }
    guard frames.count >= count else { throw NSError(domain: "MultiFrameProbe.ShortClip", code: frames.count) }
    reader.cancelReading(); return frames
}
@available(macOS 26.0, *)
private func probeJob(processor: VTFrameProcessor, configuration: VTLowLatencyFrameInterpolationConfiguration,
                      previous: ProbeFrame, current: ProbeFrame, phases: [Double], stream: Bool) throws -> ProbeSample {
    // Include output allocation and parameter setup, as the production wrapper does.
    let start = CACurrentMediaTime()
    let a = VTFrameProcessorFrame(buffer: previous.buffer, presentationTimeStamp: CMTime(seconds: previous.time, preferredTimescale: 600_000))!
    let b = VTFrameProcessorFrame(buffer: current.buffer, presentationTimeStamp: CMTime(seconds: current.time, preferredTimescale: 600_000))!
    let buffers = try phases.map { _ in try probeBuffer(width: configuration.frameWidth, height: configuration.frameHeight, attributes: configuration.destinationPixelBufferAttributes) }
    let destinations = zip(phases, buffers).map { phase, buffer in
        VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: CMTime(seconds: previous.time + (current.time - previous.time) * phase, preferredTimescale: 600_000))!
    }
    guard let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: b, previousFrame: a,
        interpolationPhase: phases.map { Float($0) }, destinationFrames: destinations) else {
        throw NSError(domain: "MultiFrameProbe.Parameters", code: 1)
    }
    let result = ProbeResult()
    if stream {
        Task.detached {
            do {
                for try await frame in processor.process(parameters: parameters) {
                    let phase = (CMTimeGetSeconds(frame.timeStamp) - previous.time) / (current.time - previous.time)
                    result.outputs.append((phase, (CACurrentMediaTime() - start) * 1000))
                }
            } catch { result.error = error }
            result.done.signal()
        }
    } else {
        processor.process(parameters: parameters) { _, error in
            result.error = error
            result.outputs = phases.map { ($0, (CACurrentMediaTime() - start) * 1000) }
            result.done.signal()
        }
    }
    guard result.done.wait(timeout: .now() + 10) == .success else { throw NSError(domain: "MultiFrameProbe.Timeout", code: 1) }
    if let error = result.error { throw error }
    let total = (CACurrentMediaTime() - start) * 1000
    guard result.outputs.count == phases.count else { throw NSError(domain: "MultiFrameProbe.OutputCount", code: result.outputs.count) }
    let outputs = zip(phases, buffers).map { phase, buffer -> ProbeOutput in
        let arrival = result.outputs.first { abs($0.0 - phase) < 0.005 }?.1 ?? -1
        return ProbeOutput(phase: phase, readyMS: arrival, meanLuma: probeLuma(buffer))
    }
    guard outputs.allSatisfy({ $0.readyMS >= 0 && $0.meanLuma > 1 }) else { throw NSError(domain: "MultiFrameProbe.EmptyOutput", code: 1) }
    return ProbeSample(totalMS: total, outputs: outputs)
}
func runMultiFrameProbe(clipPath: String, outputPath: String, sampleCount: Int, inputStride: Int = 1) throws {
    guard #available(macOS 26.0, *), VTLowLatencyFrameInterpolationConfiguration.isSupported else {
        throw NSError(domain: "MultiFrameProbe.Unsupported", code: 1)
    }
    let warmupCount = 8
    let decoded = try probeFrames(clipPath, count: (sampleCount + warmupCount + 1) * inputStride)
    let frames = decoded.enumerated().filter { $0.offset % inputStride == 0 }.map { $0.element }
    guard let device = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "MultiFrameProbe.NoMetal", code: 1) }
    guard frames.allSatisfy({ CVPixelBufferGetWidth($0.buffer) == 1920 && CVPixelBufferGetHeight($0.buffer) == 1080 }) else { throw NSError(domain: "MultiFrameProbe.Requires1080pInput", code: 1) }
    let context = CIContext(mtlDevice: device)
    var runs: [ProbeRun] = []
    var scaleMS: [Double] = []
    for width in [1920, 1280] {
        let height = width * 9 / 16
        let input: [ProbeFrame]
        if width == 1920 { input = frames }
        else {
            input = try frames.map { frame in
                let buffer = try probeBuffer(width: width, height: height, attributes: [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                let start = CACurrentMediaTime()
                let image = CIImage(cvPixelBuffer: frame.buffer).transformed(by: CGAffineTransform(scaleX: Double(width) / Double(CVPixelBufferGetWidth(frame.buffer)), y: Double(height) / Double(CVPixelBufferGetHeight(frame.buffer))))
                context.render(image, to: buffer)
                scaleMS.append((CACurrentMediaTime() - start) * 1000)
                return ProbeFrame(buffer: buffer, time: frame.time)
            }
        }
        // A level is a dyadic phase-grid depth, not the literal output count.
        for (level, phases) in [(1,[0.5]), (2,[0.5]), (2,[0.25,0.5,0.75]), (3,[0.125,0.25,0.375,0.5,0.625,0.75,0.875])] {
            for stream in [false, true] {
                let setupStart = CACurrentMediaTime()
                var samples: [ProbeSample] = [], warmup: [Double] = [], failure: String?
                let processor = VTFrameProcessor()
                do {
                    guard let configuration = VTLowLatencyFrameInterpolationConfiguration(frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: level) else { throw NSError(domain: "MultiFrameProbe.ConfigurationRejected", code: level) }
                    try processor.startSession(configuration: configuration)
                    let setup = (CACurrentMediaTime() - setupStart) * 1000
                    for index in 0..<(sampleCount + warmupCount) {
                        let sample = try probeJob(processor: processor, configuration: configuration, previous: input[index], current: input[index + 1], phases: phases, stream: stream)
                        if index < warmupCount { warmup.append(sample.totalMS) } else { samples.append(sample) }
                    }
                    runs.append(ProbeRun(width: width,height: height,level: level,phases: phases,delivery: stream ? "stream" : "batch",setupMS: setup,warmupMS: warmup,samples: samples,error: nil))
                } catch { failure = String(describing: error) }
                processor.endSession()
                if let failure { runs.append(ProbeRun(width: width,height: height,level: level,phases: phases,delivery: stream ? "stream" : "batch",setupMS: (CACurrentMediaTime()-setupStart)*1000,warmupMS: warmup,samples: samples,error: failure)) }
                let last = runs.last!
                let sorted = samples.map(\.totalMS).sorted()
                print("MULTIFRAME \(width)x\(height) level=\(level) outputs=\(phases.count) \(last.delivery) samples=\(samples.count) p50=\(sorted.isEmpty ? -1 : sorted[sorted.count/2]) error=\(failure ?? "none")")
                fflush(stdout)
            }
        }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    let object: [String: Any] = ["source": URL(fileURLWithPath: clipPath).lastPathComponent,"inputStride":inputStride,"displayMaximumFPS":NSScreen.screens.map { $0.maximumFramesPerSecond },"device": device.name,"os": ProcessInfo.processInfo.operatingSystemVersionString,"samplesPerRun":sampleCount,"warmupCount":warmupCount,"scaledInputPreparationMS":scaleMS,"runs":try JSONSerialization.jsonObject(with:encoder.encode(runs)),"limits":"sequential decoded-frame workload; excludes live game GPU contention, capture conversion, output upscaling and physical display latency"]
    let url = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]).write(to: url)
    print("RESULT \(url.path)")
}
