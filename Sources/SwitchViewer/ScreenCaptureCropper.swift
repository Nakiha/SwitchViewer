import CoreVideo
import Foundation

/// Runs on the capture output queue, before cadence detection and downsampling.
/// Display insets come from NSScreen; window title bars are conservatively detected.
final class ScreenCaptureCropper {
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var sourceSize = CGSize.zero
    private var settledWindowTop: Int?
    private var candidateTop = -1
    private var confirmations = 0

    func process(_ source: CVPixelBuffer, displayTopFraction: Double?,
                 windowScale: Double) -> (buffer: CVPixelBuffer, top: Int)? {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(source) == 2 else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let size = CGSize(width: width, height: height)
        if size != sourceSize {
            sourceSize = size
            settledWindowTop = nil
            candidateTop = -1
            confirmations = 0
        }
        let top: Int
        if let displayTopFraction {
            top = Int((Double(height) * displayTopFraction).rounded(.up))
        } else {
            if settledWindowTop == nil {
                let detected = Self.detectTitleBar(source, scale: windowScale)
                if detected == candidateTop { confirmations += 1 }
                else { candidateTop = detected; confirmations = 1 }
                // Lock geometry until the source size changes, avoiding aspect flicker.
                if confirmations >= 3 { settledWindowTop = detected }
            }
            top = settledWindowTop ?? 0
        }
        let evenTop = top + top % 2
        guard evenTop > 0, evenTop < height / 8, width % 2 == 0,
              height % 2 == 0 else { return (source, 0) }
        guard let output = copy(source, top: evenTop) else { return nil }
        return (output, evenTop)
    }

    /// Require a neutral, nearly flat gray strip with an edge at title-bar height.
    /// Black letterboxing and textured game content do not qualify.
    static func detectTitleBar(_ source: CVPixelBuffer, scale: Double) -> Int {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard width >= 320, height >= 240, scale > 0,
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return 0 }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(source, 1) else { return 0 }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
        let maximum = min(height / 8, Int(44 * scale))
        var baseline: Double?
        for y in 2..<maximum {
            var values: [Double] = []
            var neutral = true
            for sample in 0..<32 {
                // Skip traffic lights, title text, and rounded corners.
                let x = (width * (60 + sample)) / 100
                let value = yBase.load(fromByteOffset: y * yStride + x, as: UInt8.self)
                values.append(Double(value))
                let uvOffset = (y / 2) * uvStride + (x / 2) * 2
                let u = Int(uvBase.load(fromByteOffset: uvOffset, as: UInt8.self))
                let v = Int(uvBase.load(fromByteOffset: uvOffset + 1, as: UInt8.self))
                if abs(u - 128) > 4 || abs(v - 128) > 4 { neutral = false }
            }
            let mean = values.reduce(0, +) / Double(values.count)
            if baseline == nil {
                guard neutral, mean >= 28, mean <= 235,
                      values.max()! - values.min()! <= 6 else { return 0 }
                baseline = mean
            }
            if !neutral || values.max()! - values.min()! > 8 || abs(mean - baseline!) > 8 {
                return Double(y) >= 18 * scale && Double(y) <= 40 * scale ? y : 0
            }
        }
        return 0
    }

    private func copy(_ source: CVPixelBuffer, top: Int) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source) - top
        let size = CGSize(width: width, height: height)
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            pool = nil
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            poolSize = size
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey: 16] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &output) == kCVReturnSuccess,
              let output else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        for plane in 0..<2 {
            guard let inputBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let outputBase = CVPixelBufferGetBaseAddressOfPlane(output, plane) else { return nil }
            let inputStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let outputStride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
            let rowOffset = plane == 0 ? top : top / 2
            for row in 0..<CVPixelBufferGetHeightOfPlane(output, plane) {
                memcpy(outputBase.advanced(by: row * outputStride),
                       inputBase.advanced(by: (row + rowOffset) * inputStride), width)
            }
        }
        // Preserve color interpretation, but not geometry metadata describing the old image.
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferYCbCrMatrixKey, kCVImageBufferCGColorSpaceKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            }
        }
        return output
    }
}
