import CoreVideo
import Foundation
import Metal
import QuartzCore

struct NV12ResizeMetrics {
    let encodeCPUMilliseconds: Double
    let commitToGPUStartMilliseconds: Double
    let gpuExecutionMilliseconds: Double
    let commitToCompleteMilliseconds: Double

    static let zero = NV12ResizeMetrics(encodeCPUMilliseconds: 0,
                                        commitToGPUStartMilliseconds: 0,
                                        gpuExecutionMilliseconds: 0,
                                        commitToCompleteMilliseconds: 0)

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(encodeCPUMilliseconds: lhs.encodeCPUMilliseconds + rhs.encodeCPUMilliseconds,
             commitToGPUStartMilliseconds: lhs.commitToGPUStartMilliseconds + rhs.commitToGPUStartMilliseconds,
             gpuExecutionMilliseconds: lhs.gpuExecutionMilliseconds + rhs.gpuExecutionMilliseconds,
             commitToCompleteMilliseconds: lhs.commitToCompleteMilliseconds + rhs.commitToCompleteMilliseconds)
    }
}

@available(macOS 26.0, *)
final class NV12Scaler {
    enum ScalingError: Error {
        case library(String)
        case pipeline(String)
        case textureCache(OSStatus)
        case texture(OSStatus)
        case commandBuffer
        case commandEncoder
        case commandExecution(String)
        case invalidFormat
    }

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else { throw ScalingError.commandBuffer }
        self.commandQueue = queue
        let shader = #"""
        #include <metal_stdlib>
        using namespace metal;

        float cubicWeight(float distance) {
            float x = abs(distance);
            if (x < 1.0) return 1.5 * x * x * x - 2.5 * x * x + 1.0;
            if (x < 2.0) return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0;
            return 0.0;
        }

        kernel void resizePlane(texture2d<float, access::read> input [[texture(0)]],
                                texture2d<float, access::write> output [[texture(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
            uint outputWidth = output.get_width();
            uint outputHeight = output.get_height();
            if (gid.x >= outputWidth || gid.y >= outputHeight) return;

            uint inputWidth = input.get_width();
            uint inputHeight = input.get_height();
            if (inputWidth == outputWidth * 2 && inputHeight == outputHeight * 2) {
                uint2 origin = gid * 2;
                float4 value = input.read(origin)
                             + input.read(origin + uint2(1, 0))
                             + input.read(origin + uint2(0, 1))
                             + input.read(origin + uint2(1, 1));
                output.write(value * 0.25, gid);
                return;
            }

            float2 position = ((float2(gid) + 0.5) *
                               float2(inputWidth, inputHeight) /
                               float2(outputWidth, outputHeight)) - 0.5;
            int2 base = int2(floor(position));
            float2 fraction = fract(position);
            int2 maximum = int2(inputWidth - 1, inputHeight - 1);
            float4 value = float4(0.0);
            for (int y = -1; y <= 2; ++y) {
                float4 row = float4(0.0);
                for (int x = -1; x <= 2; ++x) {
                    int2 coordinate = clamp(base + int2(x, y), int2(0), maximum);
                    row += input.read(uint2(coordinate)) * cubicWeight(fraction.x - float(x));
                }
                value += row * cubicWeight(fraction.y - float(y));
            }
            output.write(clamp(value, 0.0, 1.0), gid);
        }
        """#
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            guard let function = library.makeFunction(name: "resizePlane") else {
                throw ScalingError.library("缺少 resizePlane Metal 函数")
            }
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw ScalingError.pipeline(error.localizedDescription)
        }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw ScalingError.textureCache(status) }
        self.textureCache = cache
    }

    /// Encodes NV12 scaling commands only. The caller owns command buffer submission.
    func encodeScale(source: CVPixelBuffer,
                     destination: CVPixelBuffer,
                     into commandBuffer: MTLCommandBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(source) == 2,
              CVPixelBufferGetPlaneCount(destination) == 2 else {
            throw ScalingError.invalidFormat
        }
        var textures: [CVMetalTexture] = []
        for plane in 0..<2 {
            let format: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
            let sourceWidth = CVPixelBufferGetWidthOfPlane(source, plane)
            let sourceHeight = CVPixelBufferGetHeightOfPlane(source, plane)
            let destinationWidth = CVPixelBufferGetWidthOfPlane(destination, plane)
            let destinationHeight = CVPixelBufferGetHeightOfPlane(destination, plane)
            var sourceTexture: CVMetalTexture?
            var destinationTexture: CVMetalTexture?
            let sourceStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, source, nil, format,
                sourceWidth, sourceHeight, plane, &sourceTexture)
            let destinationStatus = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, destination, nil, format,
                destinationWidth, destinationHeight, plane, &destinationTexture)
            guard sourceStatus == kCVReturnSuccess, let sourceTexture,
                  destinationStatus == kCVReturnSuccess, let destinationTexture,
                  let sourceMetalTexture = CVMetalTextureGetTexture(sourceTexture),
                  let destinationMetalTexture = CVMetalTextureGetTexture(destinationTexture) else {
                throw ScalingError.texture(sourceStatus != kCVReturnSuccess ? sourceStatus : destinationStatus)
            }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw ScalingError.commandEncoder
            }
            textures.append(sourceTexture)
            textures.append(destinationTexture)
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(sourceMetalTexture, index: 0)
            encoder.setTexture(destinationMetalTexture, index: 1)
            let group = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: destinationWidth, height: destinationHeight, depth: 1)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            encoder.endEncoding()
        }

        // Keep the Core Video texture wrappers alive until their encoded GPU work finishes.
        let retainedTextures = textures
        commandBuffer.addCompletedHandler { _ in
            withExtendedLifetime(retainedTextures) {}
        }
    }

    /// Temporary synchronous adapter for the existing lab and realtime call sites.
    func scaleSynchronously(_ source: CVPixelBuffer,
                            into destination: CVPixelBuffer) throws -> NV12ResizeMetrics {
        let encodeStart = CACurrentMediaTime()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { throw ScalingError.commandBuffer }
        try encodeScale(source: source, destination: destination, into: commandBuffer)
        let commitTime = CACurrentMediaTime()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let completedTime = CACurrentMediaTime()
        if let error = commandBuffer.error {
            throw ScalingError.commandExecution(error.localizedDescription)
        }
        let gpuStart = commandBuffer.gpuStartTime
        let gpuEnd = commandBuffer.gpuEndTime
        return NV12ResizeMetrics(
            encodeCPUMilliseconds: max(0, commitTime - encodeStart) * 1_000,
            commitToGPUStartMilliseconds: gpuStart > 0
                ? max(0, gpuStart - commitTime) * 1_000 : 0,
            gpuExecutionMilliseconds: gpuStart > 0 && gpuEnd >= gpuStart
                ? (gpuEnd - gpuStart) * 1_000 : 0,
            commitToCompleteMilliseconds: max(0, completedTime - commitTime) * 1_000)
    }
}
