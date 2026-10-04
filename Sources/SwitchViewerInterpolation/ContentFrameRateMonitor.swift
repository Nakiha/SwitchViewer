import CoreVideo
import Foundation

/// Read-only content telemetry, independent of interpolation and presentation.
/// Prefer regional repeated-frame cadence for console capture (which can have
/// a faster UI overlay); otherwise measure distinct sampled content updates.
public final class ContentFrameRateMonitor {
    private let lock = NSLock()
    private let captureDetector = SwitchFrameCadenceDetector()
    private let contentDetector = ContentFrameCadenceDetector()
    private var generation = -1
    private var captureCadence = false
    private var format: [Int] = []
    private var lastDistinctTime: Double?

    public init() {}

    public func observe(_ buffer: CVPixelBuffer, signature: DisplayFrameSignature?,
                        time: Double, captureCadence: Bool, generation: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard generation >= self.generation else { return nil }
        let format = [CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer),
                      Int(CVPixelBufferGetPixelFormatType(buffer))]
        if generation != self.generation || captureCadence != self.captureCadence || format != self.format {
            resetDetectors()
            self.generation = generation
            self.captureCadence = captureCadence
            self.format = format
        }
        guard time.isFinite, let signature else { resetDetectors(); return nil }
        let content = contentDetector.observe(signature: signature, time: time)
        if !content.isDuplicate { lastDistinctTime = time }
        let cadence = captureCadence
            ? captureDetector.observe(buffer, presentationTime: time, signature: signature).gameFPS : nil
        if let cadence { return cadence }
        if content.isDuplicate, let lastDistinctTime, time - lastDistinctTime >= 0.5 { return 0 }
        return content.observedFPS
    }

    private func resetDetectors() {
        captureDetector.reset()
        contentDetector.reset()
        lastDistinctTime = nil
    }
}
