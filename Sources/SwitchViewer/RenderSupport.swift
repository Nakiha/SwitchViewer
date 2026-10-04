import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

let maximumPresentationInFlightFrames = 3

func presentationHostTimeNow() -> CFTimeInterval {
    CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
}

enum PresentationPacingMode: Int, CaseIterable {
    case displayDriven = 0
    case cadenceLimited = 1
    case deadlineScheduled = 2

    var label: String {
        switch self {
        case .displayDriven: return "即时显示（实验）"
        case .cadenceLimited: return "按画面更新节奏显示"
        case .deadlineScheduled: return "按视频时间显示（实验）"
        }
    }

    func minimumDuration(for cadenceDuration: TimeInterval?) -> TimeInterval? {
        self == .cadenceLimited ? cadenceDuration : nil
    }
}

// MARK: - Metal 渲染视图

final class PreviewView: NSView {
    let metalLayer = CAMetalLayer()
    var fallbackLayer: AVCaptureVideoPreviewLayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = maximumPresentationInFlightFrames
        metalLayer.contentsScale = 2.0
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
        fallbackLayer?.frame = bounds
        let s = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = s
        fallbackLayer?.contentsScale = s
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * s),
                                         height: max(1, bounds.height * s))
    }
}

// MARK: - 色彩模式

enum ColorMode: Int, CaseIterable {
    case auto = 0, rec709Limited, rec709Full, rec601Limited, rec601Full
    var label: String {
        switch self {
        case .auto: return "自动"
        case .rec709Limited: return "BT.709 · 视频范围"
        case .rec709Full: return "BT.709 · 全范围"
        case .rec601Limited: return "BT.601 · 视频范围"
        case .rec601Full: return "BT.601 · 全范围"
        }
    }
}

// MARK: - Metal YUV 渲染器（NV12 → RGB，精确控制色域/范围）

final class MetalRenderer {
    let device: MTLDevice
    private var sourceProxyScaler: AnyObject?
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    var cache: CVMetalTextureCache?
    weak var layer: CAMetalLayer?
    var colorMode: ColorMode = .auto

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vs(uint vid [[vertex_id]], constant float2 *scale [[buffer(0)]]) {
        float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        float2 t[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
        VOut o;
        o.pos = float4(p[vid] * (*scale), 0, 1);
        o.uv = t[vid];
        return o;
    }
    fragment float4 fs(VOut in [[stage_in]],
                       texture2d<float> yTex [[texture(0)]],
                       texture2d<float> cTex [[texture(1)]],
                       constant float3x3 &m [[buffer(0)]],
                       constant float4 &op [[buffer(1)]]) {
        constexpr sampler s(address::clamp_to_edge, filter::linear);
        float y = yTex.sample(s, in.uv).r;
        float2 c = cTex.sample(s, in.uv).rg;
        float3 rgb = m * float3(y, c.x, c.y) + op.xyz;
        return float4(rgb, 1.0);
    }
    """

    enum RendererError: Error, CustomStringConvertible {
        case noDevice
        case noQueue
        case library(String)
        case noFunctions
        case pipeline(String)
        var description: String {
            switch self {
            case .noDevice: return "无 Metal 设备"
            case .noQueue: return "建命令队列失败"
            case .library(let s): return "shader 编译失败：\(s)"
            case .noFunctions: return "找不到 vs/fs 入口"
            case .pipeline(let s): return "建渲染管线失败：\(s)"
            }
        }
    }

    static func fourcc(_ f: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((f >> 24) & 0xFF), UInt8((f >> 16) & 0xFF),
                              UInt8((f >> 8) & 0xFF), UInt8(f & 0xFF)]
        if let s = String(bytes: bytes, encoding: .ascii),
           s.allSatisfy({ $0.isLetter || $0.isNumber }) { return s }
        return String(format: "%08X", f)
    }

    init(layer: CAMetalLayer) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RendererError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RendererError.noQueue }
        self.device = device
        self.queue = queue
        self.layer = layer
        // 关键：显示层必须绑定同一个 device，否则 nextDrawable() 永远返回 nil
        layer.device = device
        let lib: MTLLibrary
        do {
            lib = try device.makeLibrary(source: Self.shader, options: nil)
        } catch {
            throw RendererError.library(String(describing: error))
        }
        guard let vs = lib.makeFunction(name: "vs"),
              let fs = lib.makeFunction(name: "fs") else { throw RendererError.noFunctions }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vs
        desc.fragmentFunction = fs
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            throw RendererError.pipeline(String(describing: error))
        }
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        self.cache = c
    }

    /// 离屏自检：合成一帧 NV12 灰场画到临时纹理，nil=通过，否则为原因
    func selfTest() -> String? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let st = CVPixelBufferCreate(nil, 64, 32,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { return "建测试缓冲失败 status=\(st)" }
        CVPixelBufferLockBaseAddress(buf, [])
        if let y = CVPixelBufferGetBaseAddressOfPlane(buf, 0) {
            memset(y, 100, CVPixelBufferGetBytesPerRowOfPlane(buf, 0) * 32)
        }
        if let c = CVPixelBufferGetBaseAddressOfPlane(buf, 1) {
            memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(buf, 1) * 16)
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                          width: 64, height: 32, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: td) else { return "建测试纹理失败" }
        return encode(pixelBuffer: buf, to: target, scale: SIMD2<Float>(1, 1), present: nil)
    }

    // 根据附件矩阵 + 手动模式计算转换矩阵/偏移
    func uniforms(for pb: CVPixelBuffer) -> (simd_float3x3, SIMD4<Float>) {
        var use601 = false
        if let v = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String,
           v == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
            use601 = true
        }
        var limited = true
        switch colorMode {
        case .auto: break // 有限范围 + 附件矩阵（默认 709）
        case .rec709Limited: use601 = false; limited = true
        case .rec709Full: use601 = false; limited = false
        case .rec601Limited: use601 = true; limited = true
        case .rec601Full: use601 = true; limited = false
        }
        // BT.709 / BT.601 基矩阵（列向量：Y 列，Cb 列，Cr 列）
        let c0 = SIMD3<Float>(1, 1, 1)
        let c1: SIMD3<Float>
        let c2: SIMD3<Float>
        if use601 {
            c1 = SIMD3<Float>(0, -0.344136, 1.772)
            c2 = SIMD3<Float>(1.402, -0.714136, 0)
        } else {
            c1 = SIMD3<Float>(0, -0.1873, 1.8556)
            c2 = SIMD3<Float>(1.5748, -0.4681, 0)
        }
        let ys: Float = limited ? 255.0 / 219.0 : 1.0
        let cs: Float = limited ? 255.0 / 224.0 : 1.0
        let m = simd_float3x3(c0 * ys, c1 * cs, c2 * cs)
        let rawOff: SIMD3<Float> = limited
            ? SIMD3<Float>(-16.0 / 255.0, -128.0 / 255.0, -128.0 / 255.0)
            : SIMD3<Float>(0, -0.5, -0.5)
        let o = m * rawOff
        return (m, SIMD4<Float>(o, 0))
    }

    /// 核心编码：画到指定纹理；present 非空时一并呈现。nil=成功，否则为原因
    func encode(pixelBuffer sourcePB: CVPixelBuffer, to target: MTLTexture,
                scale: SIMD2<Float>, present drawable: MTLDrawable?,
                minimumPresentationDuration: TimeInterval? = nil,
                targetPresentationHostTime: CFTimeInterval? = nil,
                onPresented: ((CFTimeInterval) -> Void)? = nil,
                onCommandBufferCommitted: (() -> Void)? = nil,
                onGPUCompleted: (() -> Void)? = nil,
                softenSource: Bool = false) -> String? {
        guard let cache = cache else { return "无纹理缓存" }
        guard let buf = queue.makeCommandBuffer() else { return "建命令缓冲失败" }
        let pb: CVPixelBuffer
        if softenSource, #available(macOS 26.0, *) {
            do {
                if sourceProxyScaler == nil { sourceProxyScaler = try SourceFrameProxyScaler(device: device) }
                pb = try (sourceProxyScaler as! SourceFrameProxyScaler).encode(source: sourcePB, into: buf)
            } catch { return "原始帧代理缩放失败：\(error)" }
        } else { pb = sourcePB }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var yRef: CVMetalTexture?
        var cRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .r8Unorm, w, h, 0, &yRef)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .rg8Unorm, w / 2, h / 2, 1, &cRef)
        guard let yTex = yRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return "Y纹理失败" }
        guard let cTex = cRef.flatMap({ CVMetalTextureGetTexture($0) }) else { return "CbCr纹理失败" }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let enc = buf.makeRenderCommandEncoder(descriptor: pass) else { return "建编码器失败" }
        var s = scale
        var (m, o) = uniforms(for: pb)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&s, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        enc.setFragmentTexture(yTex, index: 0)
        enc.setFragmentTexture(cTex, index: 1)
        enc.setFragmentBytes(&m, length: MemoryLayout<simd_float3x3>.size, index: 0)
        enc.setFragmentBytes(&o, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        buf.addCompletedHandler { _ in withExtendedLifetime((pb, yRef, cRef)) {} }
        if let onGPUCompleted {
            buf.addCompletedHandler { _ in onGPUCompleted() }
        }
        if let d = drawable {
            if let onPresented {
                d.addPresentedHandler { drawable in
                    onPresented(drawable.presentedTime)
                }
            }
            if let targetPresentationHostTime, targetPresentationHostTime > 0 {
                buf.present(d, atTime: targetPresentationHostTime)
            } else if let duration = minimumPresentationDuration, duration > 0 {
                buf.present(d, afterMinimumDuration: duration)
            } else {
                buf.present(d)
            }
        }
        onCommandBufferCommitted?()
        buf.commit()
        return nil
    }

    /// 成功返回 (true, nil)；失败返回 (false, 原因)
    func render(pixelBuffer pb: CVPixelBuffer,
                referenceAspect: Float? = nil,
                softenSource: Bool = false,
                minimumPresentationDuration: TimeInterval? = nil,
                targetPresentationHostTime: CFTimeInterval? = nil,
                onPresented: ((CFTimeInterval) -> Void)? = nil,
                onDrawableWaitStarted: (() -> Void)? = nil,
                onDrawableAcquired: (() -> Void)? = nil,
                onCommandBufferCommitted: (() -> Void)? = nil,
                onGPUCompleted: (() -> Void)? = nil) -> (Bool, String?) {
        let pf = CVPixelBufferGetPixelFormatType(pb)
        guard pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
            return (false, "缓冲是 \(Self.fourcc(pf)) 不是 NV12")
        }
        guard let layer = layer else { return (false, "无显示层") }
        let ds = layer.drawableSize
        guard ds.width >= 1, ds.height >= 1 else { return (false, "drawableSize 为 0") }
        onDrawableWaitStarted?()
        guard let drawable = layer.nextDrawable() else { return (false, "取 drawable 失败") }
        onDrawableAcquired?()
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        // 等比适配。插值帧传入所属源帧的宽高比，保证与源帧显示比例一致。
        let viewAspect = Float(ds.width / max(1, ds.height))
        let videoAspect = referenceAspect ?? (Float(w) / Float(max(1, h)))
        let scale: SIMD2<Float>
        if videoAspect >= viewAspect {
            scale = SIMD2<Float>(1, viewAspect / videoAspect)
        } else {
            scale = SIMD2<Float>(videoAspect / viewAspect, 1)
        }
        if let err = encode(pixelBuffer: pb, to: drawable.texture, scale: scale,
                            present: drawable,
                            minimumPresentationDuration: minimumPresentationDuration,
                            targetPresentationHostTime: targetPresentationHostTime,
                            onPresented: onPresented,
                            onCommandBufferCommitted: onCommandBufferCommitted,
                            onGPUCompleted: onGPUCompleted,
                            softenSource: softenSource) {
            return (false, err)
        }
        return (true, nil)
    }
}

// MARK: - App

/// Appends diagnostic events to ~/Library/Logs/SwitchViewer with bounded size.
