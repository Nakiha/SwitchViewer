import CoreVideo
import CoreMedia
import Metal
import XCTest
@testable import SwitchViewerInterpolation

final class GameFrameColorTests: XCTestCase {
    /// Dark gray, saturated patches and unequal corners catch gamma/gamut changes,
    /// limited-range mistakes, sRGB hardware decoding, and vertical flips.
    func testEncodedRGBRoundTripPreservesColorAndOrientation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let converter = try GameFrameColorConverter(device: device)
        let colors: [[UInt8]] = [[0, 0, 0, 255], [32, 32, 32, 255], [64, 64, 64, 255],
            [128, 128, 128, 255], [255, 255, 255, 255], [16, 32, 220, 255],
            [220, 48, 24, 255], [32, 210, 60, 255]]
        let width = 256, height = 128
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[(y / 64) * 4 + x / 64]
                for channel in 0..<4 { bytes[(y * width + x) * 4 + channel] = color[channel] }
            }
        }
        for format: MTLPixelFormat in [.bgra8Unorm, .bgra8Unorm_srgb] {
            let source = try texture(device: device, width: width, height: height, format: format)
            bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
            let nv12 = try converter.makeNV12(from: source)
            let actual = try decode(converter: converter, buffer: nv12, device: device)
            for index in 0..<colors.count {
                let x = (index % 4) * 64 + 32, y = (index / 4) * 64 + 32
                for channel in 0..<3 {
                    XCTAssertLessThanOrEqual(abs(Int(actual[(y * width + x) * 4 + channel]) - Int(colors[index][channel])), 2,
                        "\(format) patch \(index) channel \(channel)")
                }
            }
        }
    }

    @available(macOS 26.0, *)
    func testAppleIdenticalFrameDoesNotChangeEncodedGray() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let converter = try GameFrameColorConverter(device: device)
        let width = 1920, height = 1080
        let source = try texture(device: device, width: width, height: height, format: .bgra8Unorm)
        let shades: [UInt8] = [16, 32, 64, 96, 128, 192]
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = shades[x / 320] }
            }
        }
        bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        let original = try converter.makeNV12(from: source)
        let interpolator: AppleDownsampledFrameInterpolator
        do { interpolator = try AppleDownsampledFrameInterpolator(width: width, height: height) }
        catch { throw XCTSkip("Apple interpolation unavailable: \(error)") }
        let finished = expectation(description: "Apple midpoint")
        var midpoint: CVPixelBuffer?
        var failure: Error?
        try interpolator.submit(previous: original, current: original,
            previousPresentationTimeStamp: CMTime(value: 0, timescale: 30),
            currentPresentationTimeStamp: CMTime(value: 1, timescale: 30)) { result, error in
                midpoint = result?.pixelBuffer
                failure = error
                finished.fulfill()
            }
        wait(for: [finished], timeout: 10)
        if let failure { throw failure }
        let actual = try decode(converter: converter, buffer: XCTUnwrap(midpoint), device: device)
        for (index, shade) in shades.enumerated() {
            let x = index * 320 + 160, y = height / 2
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(actual[(y * width + x) * 4 + channel]) - Int(shade)), 3,
                    "Apple midpoint changed gray \(shade)")
            }
        }
    }

    private func texture(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func decode(converter: GameFrameColorConverter, buffer: CVPixelBuffer, device: MTLDevice) throws -> [UInt8] {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let output = try texture(device: device, width: width, height: height, format: .bgra8Unorm)
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        try converter.encodeRGB(from: buffer, to: output, command: command)
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return bytes
    }
}
