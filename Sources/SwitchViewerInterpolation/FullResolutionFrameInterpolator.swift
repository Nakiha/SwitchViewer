import CoreVideo
import Foundation
import Metal
import Vision

/// A standalone, full-resolution optical-flow interpolation prototype.
/// The input and output remain NV12 so the capture path can keep its 4K buffers.
public final class FullResolutionFrameInterpolator {
    public struct Result {
        public let pixelBuffer: CVPixelBuffer
        public let opticalFlowPixelFormat: OSType
        public let flowWidth: Int
        public let flowHeight: Int
        public let centerFlowX: Float
        public let centerFlowY: Float
        public let preprocessingMilliseconds: Double
        public let opticalFlowMilliseconds: Double
        public let synthesisMilliseconds: Double
        public var totalMilliseconds: Double {
            preprocessingMilliseconds + opticalFlowMilliseconds + synthesisMilliseconds
        }
    }

    public enum InterpolationError: Error, CustomStringConvertible {
        case noMetalDevice
        case noCommandQueue
        case shader(String)
        case unsupportedPixelFormat(OSType)
        case mismatchedFrames
        case invalidPhase
        case invalidFlowScale
        case vision(String)
        case flowDimensions(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
        case pixelBufferPool(OSStatus)
        case metalTexture(String)
        case metalCommand(String)

        public var description: String {
            switch self {
            case .noMetalDevice: return "没有可用的 Metal GPU"
            case .noCommandQueue: return "无法创建 Metal 命令队列"
            case .shader(let message): return "编译合成 shader 失败：\(message)"
            case .unsupportedPixelFormat(let format): return "只支持 NV12 输入，格式代码：\(format)"
            case .mismatchedFrames: return "两帧的宽度、高度和像素格式必须相同"
            case .invalidPhase: return "插帧相位必须大于 0 且小于 1"
            case .invalidFlowScale: return "光流计算比例必须在 0.25 到 1.0 之间"
            case .vision(let message): return "Vision 光流失败：\(message)"
            case .flowDimensions(let ew, let eh, let aw, let ah):
                return "Vision 光流输出尺寸为 \(aw)×\(ah)，输入是 \(ew)×\(eh)"
            case .pixelBufferPool(let status): return "创建 NV12 输出缓冲失败，状态码：\(status)"
            case .metalTexture(let message): return "创建 Metal 纹理失败：\(message)"
            case .metalCommand(let message): return "Metal 合成失败：\(message)"
            }
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let computationAccuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy
    private let flowScale: Float
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private let downscalePipeline: MTLComputePipelineState
    private let blendLumaPipeline: MTLComputePipelineState
    private let blendChromaPipeline: MTLComputePipelineState
    private var outputPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolPixelFormat: OSType = 0
    private var flowInputPool: CVPixelBufferPool?
    private var flowInputWidth = 0
    private var flowInputHeight = 0
    private var flowInputPixelFormat: OSType = 0

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint width;
        uint height;
        uint flowWidth;
        uint flowHeight;
        float phase;
        float vectorScale;
        uint mode;
    };

    struct BlendParams {
        uint width;
        uint height;
        float phase;
    };

    struct DownscaleParams {
        uint width;
        uint height;
    };

    inline float2 sourceCoordinates(float2 uv, float2 flow, constant Params &p) {
        // Vision's half-float flow observations on this runtime are in 1/8-pixel units.
        float2 motionUV = flow * (p.vectorScale / float2(p.flowWidth, p.flowHeight));
        // The flow field maps previous-frame positions toward current-frame positions.
        return motionUV;
    }

    kernel void synthesizeLuma(
        texture2d<float, access::sample> previous [[texture(0)]],
        texture2d<float, access::sample> current [[texture(1)]],
        texture2d<float, access::sample> flow [[texture(2)]],
        texture2d<float, access::write> output [[texture(3)]],
        constant Params &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5) / float2(p.width, p.height);
        float2 f = flow.sample(s, uv).rg;
        float2 motion = sourceCoordinates(uv, f, p);
        float2 previousUV = uv - p.phase * motion;
        float2 currentUV = uv + (1.0 - p.phase) * motion;
        float a = previous.sample(s, previousUV).r;
        float b = current.sample(s, currentUV).r;
        float interpolated = mix(a, b, p.phase);
        if (p.mode == 2) {
            float motionPixels = length(motion * float2(p.width, p.height));
            float protectWeight = smoothstep(0.75, 2.5, motionPixels);
            interpolated = mix(current.sample(s, uv).r, interpolated, protectWeight);
        }
        output.write(float4(interpolated, 0, 0, 1), gid);
    }

    kernel void synthesizeChroma(
        texture2d<float, access::sample> previous [[texture(0)]],
        texture2d<float, access::sample> current [[texture(1)]],
        texture2d<float, access::sample> flow [[texture(2)]],
        texture2d<float, access::write> output [[texture(3)]],
        constant Params &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        uint width = p.width / 2;
        uint height = p.height / 2;
        if (gid.x >= width || gid.y >= height) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5) / float2(width, height);
        float2 f = flow.sample(s, uv).rg;
        float2 motion = sourceCoordinates(uv, f, p);
        float2 previousUV = uv - p.phase * motion;
        float2 currentUV = uv + (1.0 - p.phase) * motion;
        float2 a = previous.sample(s, previousUV).rg;
        float2 b = current.sample(s, currentUV).rg;
        float2 interpolated = mix(a, b, p.phase);
        if (p.mode == 2) {
            float motionPixels = length(motion * float2(p.width, p.height));
            float protectWeight = smoothstep(0.75, 2.5, motionPixels);
            interpolated = mix(current.sample(s, uv).rg, interpolated, protectWeight);
        }
        output.write(float4(interpolated, 0, 1), gid);
    }

    kernel void blendLuma(
        texture2d<float, access::sample> previous [[texture(0)]],
        texture2d<float, access::sample> current [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        constant BlendParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5) / float2(p.width, p.height);
        float a = previous.sample(s, uv).r;
        float b = current.sample(s, uv).r;
        output.write(float4(mix(a, b, p.phase), 0, 0, 1), gid);
    }

    kernel void blendChroma(
        texture2d<float, access::sample> previous [[texture(0)]],
        texture2d<float, access::sample> current [[texture(1)]],
        texture2d<float, access::write> output [[texture(2)]],
        constant BlendParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        uint width = p.width / 2;
        uint height = p.height / 2;
        if (gid.x >= width || gid.y >= height) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5) / float2(width, height);
        float2 a = previous.sample(s, uv).rg;
        float2 b = current.sample(s, uv).rg;
        output.write(float4(mix(a, b, p.phase), 0, 1), gid);
    }

    kernel void downscalePlane(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant DownscaleParams &p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.width || gid.y >= p.height) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = (float2(gid) + 0.5) / float2(p.width, p.height);
        output.write(source.sample(s, uv), gid);
    }
    """

    public init(device suppliedDevice: MTLDevice? = MTLCreateSystemDefaultDevice(),
                computationAccuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy = .medium,
                flowScale: Float = 1.0) throws {
        guard flowScale >= 0.25, flowScale <= 1.0 else { throw InterpolationError.invalidFlowScale }
        guard let device = suppliedDevice else { throw InterpolationError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw InterpolationError.noCommandQueue }
        self.device = device
        self.queue = queue
        self.computationAccuracy = computationAccuracy
        self.flowScale = flowScale
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let luma = library.makeFunction(name: "synthesizeLuma"),
                  let chroma = library.makeFunction(name: "synthesizeChroma") else {
                throw InterpolationError.shader("找不到 NV12 合成入口")
            }
            // The luma and chroma passes use the same kernel signature and parameters.
            self.pipeline = try device.makeComputePipelineState(function: luma)
            self.chromaPipeline = try device.makeComputePipelineState(function: chroma)
            guard let blendLuma = library.makeFunction(name: "blendLuma"),
                  let blendChroma = library.makeFunction(name: "blendChroma") else {
                throw InterpolationError.shader("找不到帧混合入口")
            }
            self.blendLumaPipeline = try device.makeComputePipelineState(function: blendLuma)
            self.blendChromaPipeline = try device.makeComputePipelineState(function: blendChroma)
            guard let downscale = library.makeFunction(name: "downscalePlane") else {
                throw InterpolationError.shader("找不到缩小光流输入的 Metal kernel")
            }
            self.downscalePipeline = try device.makeComputePipelineState(function: downscale)
        } catch let error as InterpolationError {
            throw error
        } catch {
            throw InterpolationError.shader(String(describing: error))
        }
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess else {
            throw InterpolationError.metalTexture("创建纹理缓存状态码：\(cacheStatus)")
        }
        self.textureCache = cache
    }

    private let chromaPipeline: MTLComputePipelineState

    /// Generates one in-between NV12 frame. `flowScale` only reduces motion-estimation
    /// input; the returned frame always keeps the capture resolution.
    /// Calls should be serialized; Vision optical-flow requests are resource intensive.
    public func interpolate(previous: CVPixelBuffer, current: CVPixelBuffer,
                            phase: Float = 0.5,
                            mode: FrameInterpolationMode = .opticalFlow) throws -> Result {
        guard phase > 0, phase < 1 else { throw InterpolationError.invalidPhase }
        let width = CVPixelBufferGetWidth(previous)
        let height = CVPixelBufferGetHeight(previous)
        let pixelFormat = CVPixelBufferGetPixelFormatType(previous)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            throw InterpolationError.unsupportedPixelFormat(pixelFormat)
        }
        guard width == CVPixelBufferGetWidth(current),
              height == CVPixelBufferGetHeight(current),
              pixelFormat == CVPixelBufferGetPixelFormatType(current) else {
            throw InterpolationError.mismatchedFrames
        }

        if mode == .frameBlend {
            let output = try makeOutput(width: width, height: height, pixelFormat: pixelFormat)
            let synthesisStart = CFAbsoluteTimeGetCurrent()
            try synthesizeBlend(previous: previous, current: current, output: output,
                                width: width, height: height, phase: phase)
            let synthesisMilliseconds = (CFAbsoluteTimeGetCurrent() - synthesisStart) * 1_000
            return Result(pixelBuffer: output, opticalFlowPixelFormat: 0,
                          flowWidth: 0, flowHeight: 0, centerFlowX: 0, centerFlowY: 0,
                          preprocessingMilliseconds: 0, opticalFlowMilliseconds: 0,
                          synthesisMilliseconds: synthesisMilliseconds)
        }

        let targetFlowWidth = max(2, (Int(Float(width) * flowScale) / 2) * 2)
        let targetFlowHeight = max(2, (Int(Float(height) * flowScale) / 2) * 2)
        let preprocessStart = CFAbsoluteTimeGetCurrent()
        let flowInputs: (previous: CVPixelBuffer, current: CVPixelBuffer)
        if targetFlowWidth == width, targetFlowHeight == height {
            flowInputs = (previous, current)
        } else {
            flowInputs = try downscaleFrames(previous: previous, current: current,
                                             width: targetFlowWidth, height: targetFlowHeight,
                                             pixelFormat: pixelFormat)
        }
        let preprocessingMilliseconds = (CFAbsoluteTimeGetCurrent() - preprocessStart) * 1_000

        let flowStart = CFAbsoluteTimeGetCurrent()
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: flowInputs.current, options: [:])
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        request.computationAccuracy = computationAccuracy
        let handler = VNImageRequestHandler(cvPixelBuffer: flowInputs.previous, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw InterpolationError.vision(error.localizedDescription)
        }
        guard let flowBuffer = request.results?.first?.pixelBuffer else {
            throw InterpolationError.vision("请求成功但没有返回光流缓冲")
        }
        let flowWidth = CVPixelBufferGetWidth(flowBuffer)
        let flowHeight = CVPixelBufferGetHeight(flowBuffer)
        let expectedFlowWidth = CVPixelBufferGetWidth(flowInputs.previous)
        let expectedFlowHeight = CVPixelBufferGetHeight(flowInputs.previous)
        guard flowWidth == expectedFlowWidth, flowHeight == expectedFlowHeight else {
            throw InterpolationError.flowDimensions(expectedWidth: expectedFlowWidth,
                                                    expectedHeight: expectedFlowHeight,
                                                    actualWidth: flowWidth, actualHeight: flowHeight)
        }
        let centerFlow = try readHalfFlow(flowBuffer, x: flowWidth / 2, y: flowHeight / 2)
        let flowMilliseconds = (CFAbsoluteTimeGetCurrent() - flowStart) * 1_000

        let output = try makeOutput(width: width, height: height, pixelFormat: pixelFormat)
        let synthesisStart = CFAbsoluteTimeGetCurrent()
        try synthesize(previous: previous, current: current, flow: flowBuffer,
                       output: output, width: width, height: height,
                       flowWidth: flowWidth, flowHeight: flowHeight, phase: phase,
                       mode: mode)
        let synthesisMilliseconds = (CFAbsoluteTimeGetCurrent() - synthesisStart) * 1_000
        return Result(pixelBuffer: output, opticalFlowPixelFormat: CVPixelBufferGetPixelFormatType(flowBuffer),
                      flowWidth: flowWidth, flowHeight: flowHeight,
                      centerFlowX: centerFlow.x, centerFlowY: centerFlow.y,
                      preprocessingMilliseconds: preprocessingMilliseconds,
                      opticalFlowMilliseconds: flowMilliseconds,
                      synthesisMilliseconds: synthesisMilliseconds)
    }

    private func downscaleFrames(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 width: Int, height: Int, pixelFormat: OSType)
        throws -> (previous: CVPixelBuffer, current: CVPixelBuffer) {
        guard let cache = textureCache else { throw InterpolationError.metalTexture("纹理缓存不可用") }
        let previousOutput = try makeFlowInput(width: width, height: height, pixelFormat: pixelFormat)
        let currentOutput = try makeFlowInput(width: width, height: height, pixelFormat: pixelFormat)
        guard let command = queue.makeCommandBuffer() else {
            throw InterpolationError.metalCommand("无法创建缩小光流输入的命令缓冲")
        }
        var parameters = DownscaleParams(width: UInt32(width), height: UInt32(height))
        let sources = [previous, current]
        let outputs = [previousOutput, currentOutput]
        for index in sources.indices {
            let source = sources[index]
            let output = outputs[index]
            let sourceY = try texture(cache: cache, buffer: source, format: .r8Unorm,
                                      width: CVPixelBufferGetWidth(source),
                                      height: CVPixelBufferGetHeight(source), plane: 0)
            let sourceUV = try texture(cache: cache, buffer: source, format: .rg8Unorm,
                                       width: CVPixelBufferGetWidth(source) / 2,
                                       height: CVPixelBufferGetHeight(source) / 2, plane: 1)
            let outputY = try texture(cache: cache, buffer: output, format: .r8Unorm,
                                      width: width, height: height, plane: 0, output: true)
            let outputUV = try texture(cache: cache, buffer: output, format: .rg8Unorm,
                                       width: width / 2, height: height / 2, plane: 1, output: true)
            guard let lumaEncoder = command.makeComputeCommandEncoder() else {
                throw InterpolationError.metalCommand("无法创建光流亮度缩放编码器")
            }
            lumaEncoder.setComputePipelineState(downscalePipeline)
            lumaEncoder.setTexture(sourceY, index: 0)
            lumaEncoder.setTexture(outputY, index: 1)
            lumaEncoder.setBytes(&parameters, length: MemoryLayout<DownscaleParams>.stride, index: 0)
            dispatch(lumaEncoder, width: width, height: height, pipeline: downscalePipeline)
            lumaEncoder.endEncoding()

            guard let chromaEncoder = command.makeComputeCommandEncoder() else {
                throw InterpolationError.metalCommand("无法创建光流色度缩放编码器")
            }
            chromaEncoder.setComputePipelineState(downscalePipeline)
            chromaEncoder.setTexture(sourceUV, index: 0)
            chromaEncoder.setTexture(outputUV, index: 1)
            chromaEncoder.setBytes(&parameters, length: MemoryLayout<DownscaleParams>.stride, index: 0)
            dispatch(chromaEncoder, width: width / 2, height: height / 2, pipeline: downscalePipeline)
            chromaEncoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw InterpolationError.metalCommand("缩小光流输入失败：\(error.localizedDescription)")
        }
        return (previousOutput, currentOutput)
    }

    private func makeFlowInput(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        if flowInputPool == nil || flowInputWidth != width || flowInputHeight != height
            || flowInputPixelFormat != pixelFormat {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                                 attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                throw InterpolationError.pixelBufferPool(status)
            }
            flowInputPool = pool
            flowInputWidth = width
            flowInputHeight = height
            flowInputPixelFormat = pixelFormat
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, flowInputPool!, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw InterpolationError.pixelBufferPool(status)
        }
        return buffer
    }

    private func readHalfFlow(_ buffer: CVPixelBuffer, x: Int, y: Int) throws -> SIMD2<Float> {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw InterpolationError.vision("光流缓冲没有可读地址")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
        return SIMD2<Float>(Float(Float16(bitPattern: row[x * 2])),
                            Float(Float16(bitPattern: row[x * 2 + 1])))
    }

    private func makeOutput(width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        if outputPool == nil || poolWidth != width || poolHeight != height || poolPixelFormat != pixelFormat {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                                 attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess, let pool else {
                throw InterpolationError.pixelBufferPool(status)
            }
            outputPool = pool
            poolWidth = width
            poolHeight = height
            poolPixelFormat = pixelFormat
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPool!, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw InterpolationError.pixelBufferPool(status)
        }
        return pixelBuffer
    }

    private func synthesize(previous: CVPixelBuffer, current: CVPixelBuffer, flow: CVPixelBuffer,
                            output: CVPixelBuffer, width: Int, height: Int,
                            flowWidth: Int, flowHeight: Int, phase: Float,
                            mode: FrameInterpolationMode) throws {
        guard let cache = textureCache else { throw InterpolationError.metalTexture("纹理缓存不可用") }
        let previousY = try texture(cache: cache, buffer: previous, format: .r8Unorm,
                                    width: width, height: height, plane: 0)
        let previousUV = try texture(cache: cache, buffer: previous, format: .rg8Unorm,
                                     width: width / 2, height: height / 2, plane: 1)
        let currentY = try texture(cache: cache, buffer: current, format: .r8Unorm,
                                   width: width, height: height, plane: 0)
        let currentUV = try texture(cache: cache, buffer: current, format: .rg8Unorm,
                                    width: width / 2, height: height / 2, plane: 1)
        let flowTexture = try texture(cache: cache, buffer: flow, format: .rg16Float,
                                      width: flowWidth, height: flowHeight, plane: 0)
        let outputY = try texture(cache: cache, buffer: output, format: .r8Unorm,
                                  width: width, height: height, plane: 0, output: true)
        let outputUV = try texture(cache: cache, buffer: output, format: .rg8Unorm,
                                   width: width / 2, height: height / 2, plane: 1, output: true)

        guard let command = queue.makeCommandBuffer() else {
            throw InterpolationError.metalCommand("无法创建命令缓冲")
        }
        var params = Params(width: UInt32(width), height: UInt32(height),
                            flowWidth: UInt32(flowWidth), flowHeight: UInt32(flowHeight),
                            phase: phase, vectorScale: 8,
                            mode: mode == .uiProtected ? 2 : 0)
        guard let lumaEncoder = command.makeComputeCommandEncoder() else {
            throw InterpolationError.metalCommand("无法创建亮度编码器")
        }
        lumaEncoder.setComputePipelineState(pipeline)
        bind(lumaEncoder, previous: previousY, current: currentY, flow: flowTexture,
             output: outputY, params: &params)
        dispatch(lumaEncoder, width: width, height: height, pipeline: pipeline)
        lumaEncoder.endEncoding()

        guard let chromaEncoder = command.makeComputeCommandEncoder() else {
            throw InterpolationError.metalCommand("无法创建色度编码器")
        }
        chromaEncoder.setComputePipelineState(chromaPipeline)
        bind(chromaEncoder, previous: previousUV, current: currentUV, flow: flowTexture,
             output: outputUV, params: &params)
        dispatch(chromaEncoder, width: width / 2, height: height / 2, pipeline: chromaPipeline)
        chromaEncoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw InterpolationError.metalCommand(error.localizedDescription)
        }
    }

    private func synthesizeBlend(previous: CVPixelBuffer, current: CVPixelBuffer,
                                 output: CVPixelBuffer, width: Int, height: Int,
                                 phase: Float) throws {
        guard let cache = textureCache else { throw InterpolationError.metalTexture("纹理缓存不可用") }
        let previousY = try texture(cache: cache, buffer: previous, format: .r8Unorm,
                                    width: width, height: height, plane: 0)
        let previousUV = try texture(cache: cache, buffer: previous, format: .rg8Unorm,
                                     width: width / 2, height: height / 2, plane: 1)
        let currentY = try texture(cache: cache, buffer: current, format: .r8Unorm,
                                   width: width, height: height, plane: 0)
        let currentUV = try texture(cache: cache, buffer: current, format: .rg8Unorm,
                                    width: width / 2, height: height / 2, plane: 1)
        let outputY = try texture(cache: cache, buffer: output, format: .r8Unorm,
                                  width: width, height: height, plane: 0, output: true)
        let outputUV = try texture(cache: cache, buffer: output, format: .rg8Unorm,
                                   width: width / 2, height: height / 2, plane: 1, output: true)
        guard let command = queue.makeCommandBuffer() else {
            throw InterpolationError.metalCommand("无法创建帧混合命令缓冲")
        }
        var params = BlendParams(width: UInt32(width), height: UInt32(height), phase: phase)
        let planes: [(MTLComputePipelineState, MTLTexture, MTLTexture, MTLTexture, Int, Int)] = [
            (blendLumaPipeline, previousY, currentY, outputY, width, height),
            (blendChromaPipeline, previousUV, currentUV, outputUV, width / 2, height / 2)
        ]
        for (pipeline, previousPlane, currentPlane, outputPlane, planeWidth, planeHeight) in planes {
            guard let encoder = command.makeComputeCommandEncoder() else {
                throw InterpolationError.metalCommand("无法创建帧混合编码器")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(previousPlane, index: 0)
            encoder.setTexture(currentPlane, index: 1)
            encoder.setTexture(outputPlane, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<BlendParams>.stride, index: 0)
            dispatch(encoder, width: planeWidth, height: planeHeight, pipeline: pipeline)
            encoder.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw InterpolationError.metalCommand("帧混合失败：\(error.localizedDescription)")
        }
    }

    private struct Params {
        var width: UInt32
        var height: UInt32
        var flowWidth: UInt32
        var flowHeight: UInt32
        var phase: Float
        var vectorScale: Float
        var mode: UInt32
    }

    private struct BlendParams {
        var width: UInt32
        var height: UInt32
        var phase: Float
    }

    private struct DownscaleParams {
        var width: UInt32
        var height: UInt32
    }

    private func bind(_ encoder: MTLComputeCommandEncoder, previous: MTLTexture, current: MTLTexture,
                      flow: MTLTexture, output: MTLTexture, params: inout Params) {
        encoder.setTexture(previous, index: 0)
        encoder.setTexture(current, index: 1)
        encoder.setTexture(flow, index: 2)
        encoder.setTexture(output, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int,
                          pipeline: MTLComputePipelineState) {
        let w = min(pipeline.threadExecutionWidth, width)
        let h = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / w, height))
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private func texture(cache: CVMetalTextureCache, buffer: CVPixelBuffer, format: MTLPixelFormat,
                         width: Int, height: Int, plane: Int, output: Bool = false) throws -> MTLTexture {
        var textureReference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer,
                                                               nil, format, width, height,
                                                               plane, &textureReference)
        guard status == kCVReturnSuccess, let reference = textureReference,
              let texture = CVMetalTextureGetTexture(reference) else {
            throw InterpolationError.metalTexture("plane=\(plane), format=\(format.rawValue), status=\(status)")
        }
        if output && !texture.usage.contains(.shaderWrite) {
            throw InterpolationError.metalTexture("输出纹理不支持 GPU 写入")
        }
        return texture
    }
}
