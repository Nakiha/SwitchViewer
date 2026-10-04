import CoreVideo
import Foundation
import Metal

/// Keeps the game's encoded RGB values intact. No gamma or gamut conversion is
/// applied here; the presentation layer must preserve the game's own colorspace.
public final class GameFrameColorConverter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let cache: CVMetalTextureCache
    private let luma: MTLComputePipelineState
    private let chroma: MTLComputePipelineState
    private let decode: MTLComputePipelineState
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Self.error("没有可用的转换队列") }
        self.queue = queue
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw Self.error("无法创建转换纹理缓存") }
        self.cache = cache
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        luma = try device.makeComputePipelineState(function: library.makeFunction(name: "rgbToLuma")!)
        chroma = try device.makeComputePipelineState(function: library.makeFunction(name: "rgbToChroma")!)
        decode = try device.makeComputePipelineState(function: library.makeFunction(name: "nv12ToRGB")!)
    }

    /// Called after the game's copied render target is GPU-ready, on the bounded
    /// interpolation worker. Waiting here never waits on the game's rendering thread.
    public func makeNV12(from source: MTLTexture) throws -> CVPixelBuffer {
        guard source.width % 2 == 0, source.height % 2 == 0 else { throw Self.error("游戏纹理尺寸必须为偶数") }
        let raw: MTLTexture
        if source.pixelFormat == .bgra8Unorm_srgb {
            guard let view = source.makeTextureView(pixelFormat: .bgra8Unorm) else {
                throw Self.error("无法读取游戏的原始 sRGB 编码值")
            }
            raw = view
        } else if source.pixelFormat == .bgra8Unorm { raw = source }
        else { throw Self.error("暂不支持此游戏纹理格式") }
        if poolSize.width != source.width || poolSize.height != source.height {
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: source.width,
                kCVPixelBufferHeightKey: source.height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &newPool) == kCVReturnSuccess else {
                throw Self.error("无法创建游戏颜色转换缓冲池")
            }
            pool = newPool
            poolSize = (source.width, source.height)
        }
        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output) == kCVReturnSuccess,
              let output, let command = queue.makeCommandBuffer() else { throw Self.error("无法创建游戏颜色转换缓冲") }
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        // Deliberately omit transfer/primaries tags: these are encoded game values,
        // not RGB color-matched to Rec.709. Apple performs temporal synthesis only.
        let (yWrapper, y) = try texture(output, plane: 0, format: .r8Unorm)
        let (uvWrapper, uv) = try texture(output, plane: 1, format: .rg8Unorm)
        try encode(luma, command: command, textures: [raw, y], width: y.width, height: y.height)
        try encode(chroma, command: command, textures: [raw, uv], width: uv.width, height: uv.height)
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime([yWrapper, uvWrapper]) {}
        if let error = command.error { throw error }
        return output
    }

    public func encodeRGB(from source: CVPixelBuffer, to target: MTLTexture, command: MTLCommandBuffer) throws {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              target.pixelFormat == .bgra8Unorm else { throw Self.error("颜色显示需要 NV12 和 BGRA8 纹理") }
        let (yWrapper, y) = try texture(source, plane: 0, format: .r8Unorm)
        let (uvWrapper, uv) = try texture(source, plane: 1, format: .rg8Unorm)
        try encode(decode, command: command, textures: [y, uv, target], width: target.width, height: target.height)
        command.addCompletedHandler { _ in withExtendedLifetime([source, yWrapper, uvWrapper]) {} }
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) throws -> (CVMetalTexture, MTLTexture) {
        var wrapper: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
            format, CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &wrapper) == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
            throw Self.error("无法映射游戏 NV12 纹理")
        }
        return (wrapper, texture)
    }

    private func encode(_ pipeline: MTLComputePipelineState, command: MTLCommandBuffer,
                        textures: [MTLTexture], width: Int, height: Int) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw Self.error("无法编码游戏颜色转换") }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
        encoder.endEncoding()
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SwitchViewer.GameColor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void rgbToLuma(texture2d<float, access::read> source [[texture(0)]],
                         texture2d<float, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        float y = dot(source.read(p).rgb, float3(0.2126, 0.7152, 0.0722));
        output.write(float4((16.0 + 219.0 * y) / 255.0, 0, 0, 1), p);
    }
    kernel void rgbToChroma(texture2d<float, access::read> source [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        uint2 q = p * 2;
        float3 rgb = (source.read(q).rgb + source.read(q + uint2(1,0)).rgb
                   + source.read(q + uint2(0,1)).rgb + source.read(q + uint2(1,1)).rgb) * 0.25;
        float cb = dot(rgb, float3(-0.114572106, -0.385427894, 0.5));
        float cr = dot(rgb, float3(0.5, -0.454152908, -0.045847092));
        output.write(float4((128.0 + 224.0 * cb) / 255.0, (128.0 + 224.0 * cr) / 255.0, 0, 1), p);
    }
    kernel void nv12ToRGB(texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]],
                         texture2d<float, access::write> output [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float2 uv = (float2(p) + 0.5) / float2(output.get_width(), output.get_height());
        float y = (luma.sample(s, uv).r * 255.0 - 16.0) / 219.0;
        float2 c = (chroma.sample(s, uv).rg * 255.0 - 128.0) / 224.0;
        float3 rgb = float3(y + 1.5748 * c.y, y - 0.187324273 * c.x - 0.468124273 * c.y, y + 1.8556 * c.x);
        output.write(float4(clamp(rgb, 0.0, 1.0), 1), p);
    }
    """
}
