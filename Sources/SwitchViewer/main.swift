import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import Darwin
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

private let maximumPresentationInFlightFrames = 3

enum PresentationPacingMode: Int, CaseIterable {
    case displayDriven = 0
    case cadenceLimited = 1

    var label: String {
        switch self {
        case .displayDriven: return "尽快呈现（低时延实验）"
        case .cadenceLimited: return "按检测节奏限速（原方式）"
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
        case .rec709Limited: return "709 有限"
        case .rec709Full: return "709 全幅"
        case .rec601Limited: return "601 有限"
        case .rec601Full: return "601 全幅"
        }
    }
}

// MARK: - Metal YUV 渲染器（NV12 → RGB，精确控制色域/范围）

final class MetalRenderer {
    let device: MTLDevice
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
    func encode(pixelBuffer pb: CVPixelBuffer, to target: MTLTexture,
                scale: SIMD2<Float>, present drawable: MTLDrawable?,
                minimumPresentationDuration: TimeInterval? = nil,
                onPresented: ((CFTimeInterval) -> Void)? = nil,
                onCommandBufferCommitted: (() -> Void)? = nil,
                onGPUCompleted: (() -> Void)? = nil) -> String? {
        guard let cache = cache else { return "无纹理缓存" }
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
        guard let buf = queue.makeCommandBuffer() else { return "建命令缓冲失败" }
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
        if let onGPUCompleted {
            buf.addCompletedHandler { _ in onGPUCompleted() }
        }
        if let d = drawable {
            if let onPresented {
                d.addPresentedHandler { drawable in
                    onPresented(drawable.presentedTime)
                }
            }
            if let duration = minimumPresentationDuration, duration > 0 {
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
                minimumPresentationDuration: TimeInterval? = nil,
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
        // 等比适配
        let viewAspect = Float(ds.width / max(1, ds.height))
        let videoAspect = Float(w) / Float(max(1, h))
        let scale: SIMD2<Float>
        if videoAspect >= viewAspect {
            scale = SIMD2<Float>(1, viewAspect / videoAspect)
        } else {
            scale = SIMD2<Float>(videoAspect / viewAspect, 1)
        }
        if let err = encode(pixelBuffer: pb, to: drawable.texture, scale: scale,
                            present: drawable,
                            minimumPresentationDuration: minimumPresentationDuration,
                            onPresented: onPresented,
                            onCommandBufferCommitted: onCommandBufferCommitted,
                            onGPUCompleted: onGPUCompleted) {
            return (false, err)
        }
        return (true, nil)
    }
}

// MARK: - App

/// Appends diagnostic events to ~/Library/Logs/SwitchViewer with bounded size.
final class RollingDiagnosticsLog {
    private let queue = DispatchQueue(label: "switchviewer.diagnostics-log")
    let directoryURL: URL
    private let fileURL: URL
    private let maxFileBytes = 2 * 1024 * 1024
    private let archiveCount = 5

    init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        directoryURL = library.appendingPathComponent("Logs/SwitchViewer", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("switchviewer.log")
    }

    func append(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            do {
                try FileManager.default.createDirectory(at: self.directoryURL,
                                                        withIntermediateDirectories: true)
                try self.rotateIfNeeded(incomingBytes: data.count)
                if FileManager.default.fileExists(atPath: self.fileURL.path) {
                    let handle = try FileHandle(forWritingTo: self.fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: self.fileURL, options: .atomic)
                }
            } catch {
                NSLog("SwitchViewer diagnostic log write failed: %@", error.localizedDescription)
            }
        }
    }

    func flush() {
        queue.sync {}
    }

    private func archiveURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent("switchviewer.\(index).log")
    }

    private func rotateIfNeeded(incomingBytes: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size + incomingBytes > maxFileBytes else { return }

        let oldest = archiveURL(archiveCount)
        if fm.fileExists(atPath: oldest.path) { try fm.removeItem(at: oldest) }
        if archiveCount > 1 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let source = archiveURL(index)
                let destination = archiveURL(index + 1)
                if fm.fileExists(atPath: source.path) {
                    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                    try fm.moveItem(at: source, to: destination)
                }
            }
        }
        try fm.moveItem(at: fileURL, to: archiveURL(1))
    }
}

typealias FrameInterpolationCompletion = (CVPixelBuffer?, CVPixelBuffer, String?, TimeInterval?) -> Void

final class PresentationFrameTiming {
    enum Stage: Hashable {
        case processingReady
        case presentationEnqueued
        case presentationQueueStarted
        case drawableWaitStarted
        case drawableAcquired
        case commandBufferSubmitStarted
        case gpuCompleted
    }

    let captureCallbackHostTime: CFTimeInterval
    private let lock = NSLock()
    private var hostTimes: [Stage: CFTimeInterval]

    init(captureCallbackHostTime: CFTimeInterval,
         processingReadyHostTime: CFTimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.captureCallbackHostTime = captureCallbackHostTime
        hostTimes = [.processingReady: processingReadyHostTime]
    }

    func mark(_ stage: Stage, at hostTime: CFTimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        hostTimes[stage] = hostTime
        lock.unlock()
    }

    func milliseconds(from start: Stage, to end: Stage) -> Double? {
        lock.lock()
        let startTime = hostTimes[start]
        let endTime = hostTimes[end]
        lock.unlock()
        guard let startTime, let endTime, endTime >= startTime else { return nil }
        return (endTime - startTime) * 1_000
    }

    func milliseconds(from start: Stage, toHostTime endTime: CFTimeInterval) -> Double? {
        lock.lock()
        let startTime = hostTimes[start]
        lock.unlock()
        guard let startTime, endTime >= startTime else { return nil }
        return (endTime - startTime) * 1_000
    }

    func callbackToDisplayMilliseconds(_ presentedTime: CFTimeInterval) -> Double? {
        guard presentedTime.isFinite, presentedTime > captureCallbackHostTime else { return nil }
        return (presentedTime - captureCallbackHostTime) * 1_000
    }

    func callbackToReadyMilliseconds() -> Double? {
        guard let readyTime = timestamp(.processingReady),
              readyTime >= captureCallbackHostTime else { return nil }
        return (readyTime - captureCallbackHostTime) * 1_000
    }

    private func timestamp(_ stage: Stage) -> CFTimeInterval? {
        lock.lock()
        let value = hostTimes[stage]
        lock.unlock()
        return value
    }
}

final class CaptureDisplayAwakeAssertion {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = 0

    func setEnabled(_ enabled: Bool) -> (changed: Bool, result: IOReturn) {
        lock.lock()
        defer { lock.unlock() }

        if enabled {
            guard assertionID == 0 else { return (false, kIOReturnSuccess) }
            var newAssertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "SwitchViewer 正在采集视频" as CFString,
                &newAssertionID)
            if result == kIOReturnSuccess { assertionID = newAssertionID }
            return (result == kIOReturnSuccess, result)
        }

        guard assertionID != 0 else { return (false, kIOReturnSuccess) }
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess { assertionID = 0 }
        return (result == kIOReturnSuccess, result)
    }

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
    }
}

struct PresentationFrame {
    let pixelBuffer: CVPixelBuffer
    let isInterpolated: Bool
    let minimumPresentationDuration: TimeInterval?
    let presentationTimestampHostTime: CFTimeInterval?
    let timing: PresentationFrameTiming
}

protocol FrameInterpolationEngine: AnyObject {
    func submit(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime,
                completion: @escaping FrameInterpolationCompletion)
    func setMode(_ mode: FrameInterpolationMode)
    func reset()
}

private enum AppleLowLatencyFrameSupport {
    static let supportedPixelFormats: Set<OSType> = {
        guard #available(macOS 26.0, *),
              VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: 1920, frameHeight: 1080, numberOfInterpolatedFrames: 1) else {
            return []
        }
        return Set(configuration.supportedPixelFormats)
    }()
}

private func canUseAppleLowLatencyFrame(width: Int, height: Int, pixelFormat: OSType) -> Bool {
    width == 1920 && height == 1080
        && AppleLowLatencyFrameSupport.supportedPixelFormats.contains(pixelFormat)
}

private func canUseAppleLowLatency4KProxy(width: Int, height: Int, pixelFormat: OSType) -> Bool {
    width == 3840 && height == 2160
        && pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        && AppleLowLatencyFrameSupport.supportedPixelFormats.contains(pixelFormat)
}

@available(macOS 26.0, *)
final class AdaptiveFrameInterpolator: FrameInterpolationEngine {
    private struct Submission {
        let buffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let completion: FrameInterpolationCompletion
        let submittedAtUptime: TimeInterval
    }

    private struct CapturedFrame {
        let buffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
    }

    private struct Input {
        let buffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        let completion: FrameInterpolationCompletion
        let previousBuffer: CVPixelBuffer?
        let previousPresentationTimeStamp: CMTime?
        let shouldInterpolate: Bool
        let repeatedGameFrame: Bool
        let cadenceMilliseconds: Double
        let submittedAtUptime: TimeInterval
        let detectedGameFPS: Double?
    }

    private struct TimingSample {
        let backend: String
        let detectedGameFPS: Double?
        let gameFrameIntervalMilliseconds: Double
        let cadenceMilliseconds: Double
        let queueMilliseconds: Double
        let preprocessingMilliseconds: Double
        let resizeEncodeCPUMilliseconds: Double
        let resizeCommitToGPUStartMilliseconds: Double
        let resizeGPUExecutionMilliseconds: Double
        let resizeCommitToCompleteMilliseconds: Double
        let resizeWallMilliseconds: Double
        let interpolationSubmitToReadyMilliseconds: Double
        let opticalFlowMilliseconds: Double
        let synthesisMilliseconds: Double
        let providerMilliseconds: Double
        let appleFrameProcessingMilliseconds: Double
        let captureToReadyMilliseconds: Double
        let proxyCacheHits: Int
        let proxyCacheMisses: Int
    }

    private let queue = DispatchQueue(label: "switchviewer.frame-interpolation")
    private let gpuQueue = DispatchQueue(label: "switchviewer.frame-interpolation-gpu")
    private let submissionLock = NSLock()
    private var processor = VTFrameProcessor()
    private let cadenceDetector = SwitchFrameCadenceDetector()
    private let onRepeatedGameFrameSkipped: () -> Void
    private let onQueuedFramesDropped: (Int) -> Void
    private let onBackendChanged: (String) -> Void
    private let onTimingReport: (String) -> Void
    private var pending: [Input] = []
    // Keep capture callbacks from building an unbounded dispatch backlog when
    // full-resolution analysis takes longer than the capture cadence.
    private var latestSubmission: Submission?
    private var isSubmissionDrainScheduled = false
    private var recentCaptureFrames: [CapturedFrame] = []
    private var timingSamples: [TimingSample] = []
    private var lastTimingReportUptime = ProcessInfo.processInfo.systemUptime
    private var isProcessing = false
    private var resetAfterCurrent = false
    private var processingDisabledError: String?
    private var sessionSetupError: String?
    private var sessionStarted = false
    private var width = 0
    private var height = 0
    private var pixelFormat: OSType = 0
    private var outputPool: CVPixelBufferPool?
    private var frameConfig: VTLowLatencyFrameInterpolationConfiguration?
    private var gpuInterpolator: FullResolutionFrameInterpolator?
    private var appleProxyInterpolator: AppleDownsampledFrameInterpolator?
    private var activeBackend: String?
    private var mode: FrameInterpolationMode = .opticalFlow

    init(onRepeatedGameFrameSkipped: @escaping () -> Void = {},
         onQueuedFramesDropped: @escaping (Int) -> Void = { _ in },
         onBackendChanged: @escaping (String) -> Void = { _ in },
         onTimingReport: @escaping (String) -> Void = { _ in }) {
        self.onRepeatedGameFrameSkipped = onRepeatedGameFrameSkipped
        self.onQueuedFramesDropped = onQueuedFramesDropped
        self.onBackendChanged = onBackendChanged
        self.onTimingReport = onTimingReport
    }

    func submit(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime,
                completion: @escaping FrameInterpolationCompletion) {
        let submission = Submission(buffer: pixelBuffer,
                                    presentationTimeStamp: presentationTimeStamp,
                                    completion: completion,
                                    submittedAtUptime: ProcessInfo.processInfo.systemUptime)
        submissionLock.lock()
        let replacedSubmission = latestSubmission
        latestSubmission = submission
        let shouldScheduleDrain = !isSubmissionDrainScheduled
        if shouldScheduleDrain { isSubmissionDrainScheduled = true }
        submissionLock.unlock()

        if replacedSubmission != nil { onQueuedFramesDropped(1) }
        if shouldScheduleDrain {
            queue.async { self.drainLatestSubmission() }
        }
    }

    private func drainLatestSubmission() {
        submissionLock.lock()
        guard let submission = latestSubmission else {
            isSubmissionDrainScheduled = false
            submissionLock.unlock()
            return
        }
        latestSubmission = nil
        submissionLock.unlock()

        let cadenceStart = ProcessInfo.processInfo.systemUptime
        let seconds = CMTimeGetSeconds(submission.presentationTimeStamp)
        let cadence: SwitchFrameCadenceDetector.Result?
        if seconds.isFinite {
            cadence = cadenceDetector.observe(submission.buffer, presentationTime: seconds)
        } else {
            cadenceDetector.reset()
            cadence = nil
        }
        let cadenceMilliseconds = (ProcessInfo.processInfo.systemUptime - cadenceStart) * 1_000

        let previousCapturedFrame = recentCaptureFrames.last
        let previousFrame: CapturedFrame?
        if let cadence, cadence.gameFPS != nil, !cadence.repeatedGameFrame,
           let distance = cadence.intervalsSincePreviousGameUpdate,
           distance > 0, recentCaptureFrames.count >= distance {
            previousFrame = recentCaptureFrames[recentCaptureFrames.count - distance]
        } else {
            previousFrame = previousCapturedFrame
        }
        recentCaptureFrames.append(CapturedFrame(buffer: submission.buffer,
                                                 presentationTimeStamp: submission.presentationTimeStamp))
        if recentCaptureFrames.count > 3 {
            recentCaptureFrames.removeFirst(recentCaptureFrames.count - 3)
        }
        if pending.count >= 2 {
            let dropped = pending.count
            pending.removeAll(keepingCapacity: true)
            onQueuedFramesDropped(dropped)
        }
        pending.append(Input(buffer: submission.buffer,
                             presentationTimeStamp: submission.presentationTimeStamp,
                             completion: submission.completion,
                             previousBuffer: previousFrame?.buffer,
                             previousPresentationTimeStamp: previousFrame?.presentationTimeStamp,
                             shouldInterpolate: cadence?.shouldInterpolate ?? false,
                             repeatedGameFrame: cadence?.gameFPS != nil && cadence?.repeatedGameFrame == true,
                             cadenceMilliseconds: cadenceMilliseconds,
                             submittedAtUptime: submission.submittedAtUptime,
                             detectedGameFPS: cadence?.gameFPS))
        processNext()

        submissionLock.lock()
        let hasMoreSubmissions = latestSubmission != nil
        if !hasMoreSubmissions { isSubmissionDrainScheduled = false }
        submissionLock.unlock()
        if hasMoreSubmissions {
            queue.async { self.drainLatestSubmission() }
        }
    }

    func reset() {
        queue.async {
            self.submissionLock.lock()
            self.latestSubmission = nil
            self.submissionLock.unlock()
            self.pending.removeAll(keepingCapacity: true)
            self.recentCaptureFrames.removeAll(keepingCapacity: true)
            self.timingSamples.removeAll(keepingCapacity: true)
            self.lastTimingReportUptime = ProcessInfo.processInfo.systemUptime
            self.cadenceDetector.reset()
            self.appleProxyInterpolator = nil
            if self.isProcessing {
                self.resetAfterCurrent = true
            } else {
                self.endVideoToolboxSession()
            }
        }
    }

    func setMode(_ mode: FrameInterpolationMode) {
        queue.async {
            guard self.mode != mode else { return }
            self.mode = mode
            self.submissionLock.lock()
            self.latestSubmission = nil
            self.submissionLock.unlock()
            for input in self.pending {
                input.completion(nil, input.buffer, nil, nil)
            }
            self.pending.removeAll(keepingCapacity: true)
            self.recentCaptureFrames.removeAll(keepingCapacity: true)
            self.timingSamples.removeAll(keepingCapacity: true)
            self.lastTimingReportUptime = ProcessInfo.processInfo.systemUptime
            self.cadenceDetector.reset()
            self.activeBackend = nil
            self.appleProxyInterpolator = nil
            self.processingDisabledError = nil
            self.sessionSetupError = nil
        }
    }

    private func processNext() {
        guard !isProcessing, !pending.isEmpty else { return }
        let input = pending.removeFirst()
        let processStartUptime = ProcessInfo.processInfo.systemUptime
        let queueMilliseconds = max(0, (processStartUptime - input.submittedAtUptime) * 1_000
                                    - input.cadenceMilliseconds)
        if processingDisabledError != nil {
            input.completion(nil, input.buffer, nil, nil)
            processNext()
            return
        }
        if !input.shouldInterpolate {
            if input.repeatedGameFrame {
                onRepeatedGameFrameSkipped()
            }
            input.completion(nil, input.buffer, nil, nil)
            processNext()
            return
        }
        guard let previousBuffer = input.previousBuffer,
              let previousPresentationTimeStamp = input.previousPresentationTimeStamp else {
            input.completion(nil, input.buffer, nil, nil)
            processNext()
            return
        }

        let interval = CMTimeSubtract(input.presentationTimeStamp, previousPresentationTimeStamp)
        let halfInterval = CMTimeGetSeconds(interval) / 2
        let frameDuration = halfInterval.isFinite && halfInterval > 0 && halfInterval < 0.5
            ? halfInterval : nil

        let selectedMode = mode
        if selectedMode == .appleLowLatency,
           !canUseAppleLowLatencyFrame(width: CVPixelBufferGetWidth(input.buffer),
                                      height: CVPixelBufferGetHeight(input.buffer),
                                      pixelFormat: CVPixelBufferGetPixelFormatType(input.buffer)) {
            selectBackend("Apple 低延迟插帧不可用（需 1920×1080、受支持的 NV12 格式）")
            input.completion(nil, input.buffer, nil, nil)
            processNext()
            return
        }
        if selectedMode == .appleLowLatency4KProxy,
           !canUseAppleLowLatency4KProxy(width: CVPixelBufferGetWidth(input.buffer),
                                         height: CVPixelBufferGetHeight(input.buffer),
                                         pixelFormat: CVPixelBufferGetPixelFormatType(input.buffer)) {
            selectBackend("Apple 4K 代理插帧不可用（需 3840×2160 NV12）")
            input.completion(nil, input.buffer, nil, nil)
            processNext()
            return
        }
        if selectedMode == .appleLowLatency4KProxy {
            let backendLabel = "Apple 低延迟插帧（4K输入→1080p代理，4K窗口显示）"
            selectBackend(backendLabel)
            endVideoToolboxSession()
            let interpolator: AppleDownsampledFrameInterpolator
            do {
                if let existing = appleProxyInterpolator {
                    interpolator = existing
                } else {
                    let created = try AppleDownsampledFrameInterpolator(
                        width: CVPixelBufferGetWidth(input.buffer),
                        height: CVPixelBufferGetHeight(input.buffer),
                        pixelFormat: CVPixelBufferGetPixelFormatType(input.buffer))
                    appleProxyInterpolator = created
                    interpolator = created
                }
            } catch {
                fail(input, message: "初始化 Apple 4K 代理插帧失败：\(error.localizedDescription)")
                return
            }
            isProcessing = true
            gpuQueue.async {
                let providerStartUptime = ProcessInfo.processInfo.systemUptime
                let result: AppleDownsampledFrameInterpolator.Result?
                let errorMessage: String?
                do {
                    result = try interpolator.interpolate(previous: previousBuffer,
                                                          current: input.buffer,
                                                          previousPresentationTimeStamp: previousPresentationTimeStamp,
                                                          currentPresentationTimeStamp: input.presentationTimeStamp)
                    errorMessage = nil
                } catch {
                    result = nil
                    errorMessage = "Apple 4K 代理插帧失败：\(error.localizedDescription)"
                }
                let providerMilliseconds = (ProcessInfo.processInfo.systemUptime - providerStartUptime) * 1_000
                self.queue.async {
                    self.recordTiming(TimingSample(
                        backend: backendLabel,
                        detectedGameFPS: input.detectedGameFPS,
                        gameFrameIntervalMilliseconds: CMTimeGetSeconds(interval) * 1_000,
                        cadenceMilliseconds: input.cadenceMilliseconds,
                        queueMilliseconds: queueMilliseconds,
                        preprocessingMilliseconds: result?.resizeMilliseconds ?? 0,
                        resizeEncodeCPUMilliseconds: result?.resizeEncodeCPUMilliseconds ?? 0,
                        resizeCommitToGPUStartMilliseconds: result?.resizeCommitToGPUStartMilliseconds ?? 0,
                        resizeGPUExecutionMilliseconds: result?.resizeGPUExecutionMilliseconds ?? 0,
                        resizeCommitToCompleteMilliseconds: result?.resizeCommitToCompleteMilliseconds ?? 0,
                        resizeWallMilliseconds: result?.resizeMilliseconds ?? 0,
                        interpolationSubmitToReadyMilliseconds: result?.interpolationSubmitToReadyMilliseconds ?? 0,
                        opticalFlowMilliseconds: 0,
                        synthesisMilliseconds: 0,
                        providerMilliseconds: providerMilliseconds,
                        appleFrameProcessingMilliseconds: result?.processorMilliseconds ?? 0,
                        captureToReadyMilliseconds: (ProcessInfo.processInfo.systemUptime
                                                     - input.submittedAtUptime) * 1_000,
                        proxyCacheHits: result?.proxyCacheHits ?? 0,
                        proxyCacheMisses: result?.proxyCacheMisses ?? 0))
                    if let errorMessage {
                        self.processingDisabledError = errorMessage
                        input.completion(nil, input.buffer, errorMessage, nil)
                    } else if let result {
                        input.completion(result.pixelBuffer, input.buffer, nil, frameDuration)
                    } else {
                        input.completion(nil, input.buffer, "Apple 4K 代理插帧没有生成输出帧", nil)
                    }
                    self.finishCurrentAndContinue()
                }
            }
            return
        }
        if requiresGPU(for: input.buffer, mode: selectedMode) {
            let backendLabel = selectedMode == .frameBlend
                ? "Metal 帧混合（全分辨率输出）"
                : "Vision + Metal GPU（全分辨率输出；\(selectedMode.label)）"
            selectBackend(backendLabel)
            endVideoToolboxSession()
            let interpolator: FullResolutionFrameInterpolator
            do {
                if let existing = gpuInterpolator {
                    interpolator = existing
                } else {
                    let created = try FullResolutionFrameInterpolator(
                        computationAccuracy: .medium, flowScale: 0.75)
                    gpuInterpolator = created
                    interpolator = created
                }
            } catch {
                fail(input, message: "初始化 GPU 插帧失败：\(error.localizedDescription)")
                return
            }
            isProcessing = true
            gpuQueue.async {
                let providerStartUptime = ProcessInfo.processInfo.systemUptime
                let result: FullResolutionFrameInterpolator.Result?
                let errorMessage: String?
                do {
                    result = try interpolator.interpolate(previous: previousBuffer,
                                                          current: input.buffer,
                                                          phase: 0.5,
                                                          mode: selectedMode)
                    errorMessage = nil
                } catch {
                    result = nil
                    errorMessage = "GPU 插帧失败：\(error.localizedDescription)"
                }
                let providerMilliseconds = (ProcessInfo.processInfo.systemUptime - providerStartUptime) * 1_000
                self.queue.async {
                    self.recordTiming(TimingSample(
                        backend: backendLabel,
                        detectedGameFPS: input.detectedGameFPS,
                        gameFrameIntervalMilliseconds: CMTimeGetSeconds(interval) * 1_000,
                        cadenceMilliseconds: input.cadenceMilliseconds,
                        queueMilliseconds: queueMilliseconds,
                        preprocessingMilliseconds: result?.preprocessingMilliseconds ?? 0,
                        resizeEncodeCPUMilliseconds: 0,
                        resizeCommitToGPUStartMilliseconds: 0,
                        resizeGPUExecutionMilliseconds: 0,
                        resizeCommitToCompleteMilliseconds: 0,
                        resizeWallMilliseconds: 0,
                        interpolationSubmitToReadyMilliseconds: 0,
                        opticalFlowMilliseconds: result?.opticalFlowMilliseconds ?? 0,
                        synthesisMilliseconds: result?.synthesisMilliseconds ?? 0,
                        providerMilliseconds: providerMilliseconds,
                        appleFrameProcessingMilliseconds: 0,
                        captureToReadyMilliseconds: (ProcessInfo.processInfo.systemUptime
                                                     - input.submittedAtUptime) * 1_000,
                        proxyCacheHits: 0,
                        proxyCacheMisses: 0))
                    if let errorMessage {
                        self.processingDisabledError = errorMessage
                        input.completion(nil, input.buffer, errorMessage, nil)
                        self.endVideoToolboxSession()
                    } else if let result {
                        input.completion(result.pixelBuffer, input.buffer, nil, frameDuration)
                    } else {
                        input.completion(nil, input.buffer, "GPU 插帧没有生成输出帧", nil)
                    }
                    self.finishCurrentAndContinue()
                }
            }
            return
        }

        selectBackend("Apple VideoToolbox 低延迟插帧（1920×1080）")
        guard ensureSession(for: input.buffer) else {
            fail(input, message: sessionSetupError ?? "系统插帧器无法处理当前格式或尺寸")
            return
        }
        guard let currentFrame = VTFrameProcessorFrame(buffer: input.buffer,
                                                       presentationTimeStamp: input.presentationTimeStamp),
              let previousFrame = VTFrameProcessorFrame(buffer: previousBuffer,
                                                        presentationTimeStamp: previousPresentationTimeStamp) else {
            input.completion(nil, input.buffer, "创建插帧输入帧失败", nil)
            processNext()
            return
        }

        var outputBuffer: CVPixelBuffer?
        let poolStatus = outputPool.map { CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, $0, &outputBuffer) }
            ?? kCVReturnInvalidPixelBufferAttributes
        guard poolStatus == kCVReturnSuccess, let outputBuffer else {
            input.completion(nil, input.buffer, "创建插帧输出缓冲失败 status=\(poolStatus)", nil)
            processNext()
            return
        }
        let midpoint = CMTimeAdd(previousFrame.presentationTimeStamp,
                                 CMTimeMultiplyByFloat64(interval, multiplier: 0.5))
        guard let destination = VTFrameProcessorFrame(buffer: outputBuffer,
                                                      presentationTimeStamp: midpoint),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: currentFrame,
                previousFrame: previousFrame,
                interpolationPhase: [0.5],
                destinationFrames: [destination]) else {
            input.completion(nil, input.buffer, "创建插帧参数失败", nil)
            processNext()
            return
        }

        isProcessing = true
        let providerStartUptime = ProcessInfo.processInfo.systemUptime
        processor.process(parameters: parameters) { [weak self] _, error in
            guard let self else { return }
            self.queue.async {
                let providerMilliseconds = (ProcessInfo.processInfo.systemUptime - providerStartUptime) * 1_000
                self.recordTiming(TimingSample(
                    backend: "Apple VideoToolbox 低延迟插帧（1920×1080）",
                    detectedGameFPS: input.detectedGameFPS,
                    gameFrameIntervalMilliseconds: CMTimeGetSeconds(interval) * 1_000,
                    cadenceMilliseconds: input.cadenceMilliseconds,
                    queueMilliseconds: queueMilliseconds,
                    preprocessingMilliseconds: 0,
                    resizeEncodeCPUMilliseconds: 0,
                    resizeCommitToGPUStartMilliseconds: 0,
                    resizeGPUExecutionMilliseconds: 0,
                    resizeCommitToCompleteMilliseconds: 0,
                    resizeWallMilliseconds: 0,
                    interpolationSubmitToReadyMilliseconds: providerMilliseconds,
                    opticalFlowMilliseconds: 0,
                    synthesisMilliseconds: 0,
                    providerMilliseconds: providerMilliseconds,
                    appleFrameProcessingMilliseconds: providerMilliseconds,
                    captureToReadyMilliseconds: (ProcessInfo.processInfo.systemUptime
                                                 - input.submittedAtUptime) * 1_000,
                    proxyCacheHits: 0,
                    proxyCacheMisses: 0))
                let halfInterval = CMTimeGetSeconds(interval) / 2
                let frameDuration = halfInterval.isFinite && halfInterval > 0 && halfInterval < 0.5
                    ? halfInterval : nil
                let processorError: String?
                if let error {
                    let nsError = error as NSError
                    processorError = "VideoToolbox \(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
                } else {
                    processorError = nil
                }
                if let processorError { self.processingDisabledError = processorError }
                input.completion(error == nil ? outputBuffer : nil,
                                 input.buffer,
                                 processorError,
                                 frameDuration)
                if processorError != nil {
                    self.endVideoToolboxSession()
                }
                self.finishCurrentAndContinue()
            }
        }
    }

    private func finishCurrentAndContinue() {
        isProcessing = false
        if resetAfterCurrent {
            resetAfterCurrent = false
            endVideoToolboxSession()
        }
        processNext()
    }

    private func fail(_ input: Input, message: String) {
        processingDisabledError = message
        input.completion(nil, input.buffer, message, nil)
        endVideoToolboxSession()
        processNext()
    }

    private func selectBackend(_ label: String) {
        guard activeBackend != label else { return }
        activeBackend = label
        onBackendChanged(label)
    }

    private func recordTiming(_ sample: TimingSample) {
        timingSamples.append(sample)
        if timingSamples.count > 180 {
            timingSamples.removeFirst(timingSamples.count - 180)
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTimingReportUptime >= 3, !timingSamples.isEmpty else { return }
        lastTimingReportUptime = now
        let groups = Dictionary(grouping: timingSamples, by: \.backend)
        for (backend, values) in groups {
            let detectedRates = values.compactMap(\.detectedGameFPS)
            let detectedGameFPS = detectedRates.isEmpty
                ? "未识别"
                : String(format: "%.1f", detectedRates.sorted()[detectedRates.count / 2])
            func percentile(_ select: (TimingSample) -> Double, _ fraction: Double) -> Double {
                let sorted = values.map(select).sorted()
                let index = min(sorted.count - 1,
                                max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
                return sorted[index]
            }
            func range(_ select: (TimingSample) -> Double) -> String {
                String(format: "%.1f/%.1f", percentile(select, 0.50), percentile(select, 0.95))
            }
            let proxyCacheHits = values.reduce(0) { $0 + $1.proxyCacheHits }
            let proxyCacheMisses = values.reduce(0) { $0 + $1.proxyCacheMisses }
            onTimingReport("插帧耗时 P50/P95 ms; backend=\(backend); samples=\(values.count); gameFPS=\(detectedGameFPS); gameInterval=\(range(\.gameFrameIntervalMilliseconds)); cadence=\(range(\.cadenceMilliseconds)); queue=\(range(\.queueMilliseconds)); resizeEncodeCPU=\(range(\.resizeEncodeCPUMilliseconds)); resizeQueueWait=\(range(\.resizeCommitToGPUStartMilliseconds)); resizeGPU=\(range(\.resizeGPUExecutionMilliseconds)); resizeCommitToComplete=\(range(\.resizeCommitToCompleteMilliseconds)); resizeWall=\(range(\.resizeWallMilliseconds)); proxyCache=\(proxyCacheHits)/\(proxyCacheMisses); interpolationSubmitToReady=\(range(\.interpolationSubmitToReadyMilliseconds)); apple=\(range(\.appleFrameProcessingMilliseconds)); flow=\(range(\.opticalFlowMilliseconds)); synth=\(range(\.synthesisMilliseconds)); provider=\(range(\.providerMilliseconds)); captureToReady=\(range(\.captureToReadyMilliseconds))")
        }
        timingSamples.removeAll(keepingCapacity: true)
    }

    private func requiresGPU(for buffer: CVPixelBuffer, mode: FrameInterpolationMode) -> Bool {
        mode != .appleLowLatency && mode != .appleLowLatency4KProxy
    }

    private func ensureSession(for buffer: CVPixelBuffer) -> Bool {
        sessionSetupError = nil
        let newWidth = CVPixelBufferGetWidth(buffer)
        let newHeight = CVPixelBufferGetHeight(buffer)
        let newPixelFormat = CVPixelBufferGetPixelFormatType(buffer)
        if sessionStarted, width == newWidth, height == newHeight, pixelFormat == newPixelFormat {
            return true
        }
        endVideoToolboxSession()
        if #available(macOS 27.0, *) {
            let maximumDimension = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1) ?? 0
            let maximumPixelCount = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1) ?? 0
            guard maximumDimension > 0, maximumPixelCount > 0,
                  newWidth <= maximumDimension, newHeight <= maximumDimension,
                  newWidth * newHeight <= maximumPixelCount else {
                sessionSetupError = "VideoToolbox 插帧尺寸超出本机上限；当前缓冲为 \(newWidth)×\(newHeight)"
                return false
            }
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
              let config = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: newWidth, frameHeight: newHeight, numberOfInterpolatedFrames: 1) else {
            sessionSetupError = "本机 VideoToolbox 不支持插帧配置"
            return false
        }
        guard config.supportedPixelFormats.contains(newPixelFormat) else {
            sessionSetupError = "VideoToolbox 不支持输入像素格式 \(MetalRenderer.fourcc(newPixelFormat))"
            return false
        }
        let destinationFormat = (config.destinationPixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
        guard destinationFormat == newPixelFormat else {
            sessionSetupError = "插帧器输出像素格式与采集缓冲不匹配"
            return false
        }
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                      config.destinationPixelBufferAttributes as CFDictionary,
                                      &pool) == kCVReturnSuccess,
              let pool else { return false }
        let sessionProcessor = VTFrameProcessor()
        do {
            try sessionProcessor.startSession(configuration: config)
        } catch {
            sessionSetupError = "启动 VideoToolbox 插帧会话失败：\(error.localizedDescription)"
            return false
        }
        // Give every session a fresh processor so end/start cycles cannot reuse
        // stale VideoToolbox pipeline state.
        processor = sessionProcessor
        width = newWidth
        height = newHeight
        pixelFormat = newPixelFormat
        frameConfig = config
        outputPool = pool
        sessionStarted = true
        return true
    }

    private func endVideoToolboxSession() {
        if sessionStarted { processor.endSession() }
        sessionStarted = false
        outputPool = nil
        frameConfig = nil
        width = 0
        height = 0
        pixelFormat = 0
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct DisplayLatencySample {
        let isInterpolated: Bool
        let callbackToDisplayMilliseconds: Double?
        let mediaTimestampToDisplayMilliseconds: Double?
        let callbackToReadyMilliseconds: Double?
        let readyToPresentationEnqueueMilliseconds: Double?
        let presentationQueueWaitMilliseconds: Double?
        let queueStartToDrawableMilliseconds: Double?
        let drawableWaitMilliseconds: Double?
        let drawableToCommitMilliseconds: Double?
        let gpuSubmitToCompleteMilliseconds: Double?
        let gpuCompleteToDisplayMilliseconds: Double?
    }

    var window: NSWindow!
    var rootView: NSView!
    var previewView: PreviewView!
    var devicePopup: NSPopUpButton!
    var formatPopup: NSPopUpButton!
    var volumeSlider: NSSlider!
    var isMuted = false
    var audioVolume: Float = 1
    var isAlwaysOnTop = false

    var deviceMenu: NSMenu!
    var formatMenu: NSMenu!
    var statusTextItem: NSMenuItem!
    var statusDetailsItem: NSMenuItem!
    var muteMenuItem: NSMenuItem!
    var floatMenuItem: NSMenuItem!
    var colorMenuItems: [NSMenuItem] = []

    var renderer: MetalRenderer?
    var metalInitError: String?
    var metalSelfTest: String?
    var firstRenderError: String?
    var lastRenderError: String?
    var lastSetDesc: String?
    var setVerifyDesc: String?
    var deviceLost = false
    var fallbackLayer: AVCaptureVideoPreviewLayer?
    var baseStatus = ""
    var isBaseStatus = true

    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "switchviewer.session")
    var audioPreviewOutput: AVCaptureAudioPreviewOutput?
    var currentVideoDevice: AVCaptureDevice?
    var currentAudioDevice: AVCaptureDevice?
    // macOS capture sessions can renegotiate activeFormat at startRunning. Keep the
    // device configuration lock for the active stream, as OBS does for custom formats.
    var lockedFormatDevice: AVCaptureDevice?

    struct FormatOption {
        var width: Int32
        var height: Int32
        var fps: Double
        var format: AVCaptureDevice.Format
        var subtype: FourCharCode
        var label: String
    }
    var formatOptions: [FormatOption] = []

    // 帧统计（截图 + 诊断 + fps 用）
    let framesQueue = DispatchQueue(label: "switchviewer.frames", qos: .userInteractive)
    let frameLock = NSLock()
    var frameCount = 0 // Metal 渲染成功的帧（watchdog 与 fps 只看它）
    var droppedCount = 0
    var inputQueueDropCount = 0
    var presentationLimitDropCount = 0
    var rendererFailureCount = 0
    var exactDuplicateSourceCount = 0
    var sourceCompareCount = 0
    var sourceCompareTotalMilliseconds = 0.0
    var sourceCompareMaxMilliseconds = 0.0
    var lastAcceptedSourceBuffer: CVPixelBuffer?
    var consecFails = 0
    var didLogRenderFailure = false
    var lastPixelBuffer: CVPixelBuffer?
    var lastPixelFormat: FourCharCode = 0 // 只要收到帧就记，不管渲染成败
    var lastWidth: Int = 0 // 实际收到缓冲的尺寸（跟"请求的"对照用）
    var lastHeight: Int = 0
    var lastFrameDate: Date?
    var sessionGeneration = 0
    var videoDataOutput: AVCaptureVideoDataOutput?
    // fps 计量
    var tickCount = 0
    var tickDate = Date()
    var measuredFps: Double = 0
    let presentationQueue = DispatchQueue(label: "switchviewer.presentation")
    let presentationSlots = DispatchSemaphore(value: maximumPresentationInFlightFrames)
    var frameInterpolationMenuItem: NSMenuItem!
    var frameInterpolationModeMenuItems: [NSMenuItem] = []
    var frameInterpolationMode = FrameInterpolationMode.opticalFlow
    var presentationPacingMode = PresentationPacingMode.cadenceLimited
    var presentationPacingMenuItems: [NSMenuItem] = []
    var frameInterpolationEngine: FrameInterpolationEngine?
    var frameInterpolationEnabled = false
    var frameInterpolationUnavailable = false
    var frameInterpolationEpoch = 0
    var interpolatedFrameCount = 0
    var interpolationRepeatedFrameSkipCount = 0
    var interpolationFailureCount = 0
    var lastInterpolationError: String?
    let diagnosticLog = RollingDiagnosticsLog()
    private let displayTimingQueue = DispatchQueue(label: "switchviewer.display-timing")
    private var displayTimingSamples: [DisplayLatencySample] = []
    private var lastDisplayTimingReportUptime = ProcessInfo.processInfo.systemUptime
    private struct CaptureCallbackTimingSample {
        let ptsToCallbackMilliseconds: Double?
        let callbackWorkMilliseconds: Double
    }
    private let captureCallbackTimingQueue = DispatchQueue(label: "switchviewer.capture-callback-timing")
    private var captureCallbackTimingSamples: [CaptureCallbackTimingSample] = []
    private var lastCaptureCallbackTimingReportUptime = ProcessInfo.processInfo.systemUptime
    private let captureDisplayAwakeAssertion = CaptureDisplayAwakeAssertion()

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnosticLog.append("应用启动; macOS=\(ProcessInfo.processInfo.operatingSystemVersionString); 日志目录=\(diagnosticLog.directoryURL.path)")
        buildWindow()
        buildMenu()
        do {
            let r = try MetalRenderer(layer: previewView.metalLayer)
            renderer = r
            metalSelfTest = r.selfTest()
            if let t = metalSelfTest {
                metalInitError = "自检失败：\(t)"
                enableFallback("Metal 自检失败：\(t)")
            }
        } catch {
            metalInitError = String(describing: error)
            enableFallback("Metal 初始化失败：\(metalInitError ?? "?")")
        }
        diagnosticLog.append("Metal 初始化; result=\(metalInitError ?? "OK"); selfTest=\(metalSelfTest ?? "通过")")
        diagnosticLog.append("低延迟呈现队列; maximumDrawableCount=\(maximumPresentationInFlightFrames); inFlightLimit=\(maximumPresentationInFlightFrames); presentationPacing=\(presentationPacingMode.label); captureCallbackQueueQoS=userInteractive; exactSourceDedupe=fullNV12")
        refreshDevices(selectPreferred: true)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceDisconnected(_:)),
                                               name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceConnected(_:)),
                                               name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted, object: session)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickFps()
        }
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.logPeriodicDiagnostics()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
            setCaptureDisplayAwake(false, reason: "应用退出")
            if let device = lockedFormatDevice {
                device.unlockForConfiguration()
                lockedFormatDevice = nil
            }
        }
        diagnosticLog.append("应用退出")
        diagnosticLog.flush()
    }

    func setCaptureDisplayAwake(_ enabled: Bool, reason: String) {
        let update = captureDisplayAwakeAssertion.setEnabled(enabled)
        guard update.changed || update.result != kIOReturnSuccess else { return }
        diagnosticLog.append(
            "采集期间防空闲锁屏; enabled=\(enabled); reason=\(reason); result=\(update.result)")
    }

    func logPeriodicDiagnostics() {
        frameLock.lock()
        let width = lastWidth
        let height = lastHeight
        let pixelFormat = lastPixelFormat == 0 ? "无" : fourccString(lastPixelFormat)
        let frames = frameCount
        let dropped = droppedCount
        let fps = measuredFps
        let renderError = lastRenderError ?? "无"
        let lastFrameAge = lastFrameDate.map { String(format: "%.1fs", Date().timeIntervalSince($0)) } ?? "无帧"
        let interpolationEnabled = frameInterpolationEnabled
        let interpolatedFrames = interpolatedFrameCount
        let repeatedFrameSkips = interpolationRepeatedFrameSkipCount
        let presentationPacing = presentationPacingMode.label
        let interpolationFailures = interpolationFailureCount
        let interpolationError = lastInterpolationError ?? "无"
        let inputQueueDrops = inputQueueDropCount
        let presentationLimitDrops = presentationLimitDropCount
        let rendererFailures = rendererFailureCount
        let exactDuplicateSources = exactDuplicateSourceCount
        let sourceComparisons = sourceCompareCount
        let sourceCompareTotal = sourceCompareTotalMilliseconds
        let sourceCompareMax = sourceCompareMaxMilliseconds
        frameLock.unlock()

        let selectedIndex = formatPopup.indexOfSelectedItem
        let selected = formatOptions.indices.contains(selectedIndex) ? formatOptions[selectedIndex].label : "无"
        let actual = currentVideoDevice.map(actualFormatLine) ?? "无设备"
        let sourceCompareAverage = sourceComparisons > 0
            ? sourceCompareTotal / Double(sourceComparisons) : 0
        diagnosticLog.append("定时状态; session=\(session.isRunning ? "运行中" : "停止"); preset=\(session.sessionPreset.rawValue); device=\(currentVideoDevice?.localizedName ?? "无"); audio=\(currentAudioDevice?.localizedName ?? "无"); requested=\(selected); active=\(actual); buffer=\(width)x\(height) \(pixelFormat); fps=\(String(format: "%.1f", fps)); frames=\(frames); dropped=\(dropped); inputQueueDrops=\(inputQueueDrops); presentationLimitDrops=\(presentationLimitDrops); rendererFailures=\(rendererFailures); exactDuplicateSourcesSuppressed=\(exactDuplicateSources); fullFrameComparisons=\(sourceComparisons); compareAvgMaxMs=\(String(format: "%.3f/%.3f", sourceCompareAverage, sourceCompareMax)); frameInterpolation=\(interpolationEnabled ? "开" : "关"); interpolationMode=\(frameInterpolationMode.label); presentationPacing=\(presentationPacing); interpolatedFrames=\(interpolatedFrames); repeatedFrameSkips=\(repeatedFrameSkips); interpolationFailures=\(interpolationFailures); interpolationError=\(interpolationError); lastFrame=\(lastFrameAge); renderError=\(renderError); metal=\(metalInitError ?? "OK"); fallback=\(fallbackLayer == nil ? "否" : "是"); color=\(renderer?.colorMode.label ?? "无")")
    }

    // Metal 不可用时切回系统预览层，保证不断片
    func enableFallback(_ reason: String) {
        DispatchQueue.main.async {
            guard self.fallbackLayer == nil else { return }
            self.frameLock.lock()
            self.frameInterpolationEpoch += 1
            self.frameInterpolationEnabled = false
            self.frameInterpolationMenuItem?.state = .off
            let interpolationEngine = self.frameInterpolationEngine
            self.frameLock.unlock()
            interpolationEngine?.reset()
            let l = AVCaptureVideoPreviewLayer(session: self.session)
            l.videoGravity = .resizeAspect
            // 关键：Retina 下必须跟 backingScale，否则 1x 渲染再放大，全屏全是颗粒
            l.contentsScale = self.window?.backingScaleFactor ?? 2.0
            self.previewView.metalLayer.isHidden = true
            l.frame = self.previewView.bounds
            self.previewView.layer?.addSublayer(l)
            self.fallbackLayer = l
            self.previewView.fallbackLayer = l
            self.previewView.needsLayout = true
            self.setStatus("Metal 渲染不可用（\(reason)），已切回系统预览", base: false)
        }
    }

    @objc func retryMetal(_ sender: Any) {
        fallbackLayer?.removeFromSuperlayer()
        fallbackLayer = nil
        previewView.fallbackLayer = nil
        previewView.metalLayer.isHidden = false
        frameLock.lock()
        consecFails = 0
        didLogRenderFailure = false
        firstRenderError = nil
        lastRenderError = nil
        frameLock.unlock()
        if let r = renderer {
            let t = r.selfTest()
            if t == nil {
                setStatus("Metal 自检通过，已切回 Metal 渲染", base: false)
            } else {
                setStatus("Metal 自检仍失败：\(t!)", base: false)
                enableFallback(t!)
            }
        } else {
            setStatus("Metal 未初始化：\(metalInitError ?? "?")", base: false)
        }
    }

    @objc func openDiagnosticLogs(_ sender: Any) {
        do {
            try FileManager.default.createDirectory(at: diagnosticLog.directoryURL,
                                                    withIntermediateDirectories: true)
            NSWorkspace.shared.open(diagnosticLog.directoryURL)
        } catch {
            setStatus("打开日志文件夹失败：\(error.localizedDescription)", base: false)
        }
    }

    // MARK: UI

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "SwitchViewer"
        window.minSize = NSSize(width: 640, height: 400)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.center()

        rootView = NSView(frame: window.contentView!.bounds)
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        previewView = PreviewView()
        previewView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(previewView)

        // 保留选择控件作为状态模型；用户通过 macOS 菜单栏操作。
        devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged(_:))

        formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: rootView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 SwitchViewer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏 SwitchViewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAll.target = NSApp
        appMenu.addItem(showAll)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SwitchViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        deviceMenu = NSMenu(title: "采集卡")
        formatMenu = NSMenu(title: "分辨率")

        let audioMenu = NSMenu(title: "音频")
        muteMenuItem = NSMenuItem(title: "静音", action: #selector(toggleMute(_:)), keyEquivalent: "m")
        muteMenuItem.target = self
        audioMenu.addItem(muteMenuItem)
        audioMenu.addItem(.separator())
        let volumeLabel = NSMenuItem(title: "输出音量", action: nil, keyEquivalent: "")
        volumeLabel.isEnabled = false
        audioMenu.addItem(volumeLabel)
        volumeSlider = NSSlider(value: Double(audioVolume), minValue: 0, maxValue: 1,
                                target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.controlSize = .small
        volumeSlider.isContinuous = true
        volumeSlider.frame = NSRect(x: 0, y: 0, width: 190, height: 24)
        let volumeItem = NSMenuItem()
        volumeItem.view = volumeSlider
        audioMenu.addItem(volumeItem)

        let windowMenu = NSMenu(title: "窗口")
        let fullscreen = NSMenuItem(title: "进入全屏", action: #selector(goFullscreen(_:)), keyEquivalent: "f")
        fullscreen.target = self
        windowMenu.addItem(fullscreen)
        floatMenuItem = NSMenuItem(title: "窗口置顶", action: #selector(toggleFloat(_:)), keyEquivalent: "")
        floatMenuItem.target = self
        windowMenu.addItem(floatMenuItem)

        let pictureMenu = NSMenu(title: "画面")
        let screenshot = NSMenuItem(title: "保存截图到图片文件夹", action: #selector(takeScreenshot(_:)), keyEquivalent: "s")
        screenshot.target = self
        pictureMenu.addItem(screenshot)
        pictureMenu.addItem(.separator())
        let colorParent = NSMenuItem(title: "色彩模式", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "色彩模式")
        colorMenuItems = ColorMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.label, action: #selector(selectColorMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = mode == .auto ? .on : .off
            colorMenu.addItem(item)
            return item
        }
        colorParent.submenu = colorMenu
        pictureMenu.addItem(colorParent)
        let cycleColor = NSMenuItem(title: "循环切换色彩模式", action: #selector(cycleColor(_:)), keyEquivalent: "c")
        cycleColor.target = self
        pictureMenu.addItem(cycleColor)
        pictureMenu.addItem(.separator())
        let interpolationModeParent = NSMenuItem(title: "插帧方式", action: nil, keyEquivalent: "")
        let interpolationModeMenu = NSMenu(title: "插帧方式")
        frameInterpolationModeMenuItems = FrameInterpolationMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.label, action: #selector(selectFrameInterpolationMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = mode == frameInterpolationMode ? .on : .off
            if mode == .appleLowLatency || mode == .appleLowLatency4KProxy { item.isEnabled = false }
            interpolationModeMenu.addItem(item)
            return item
        }
        interpolationModeMenu.addItem(.separator())
        let modeInfo = NSMenuItem(title: "Apple 原生插帧为 1080p；4K 输入用 1080p 代理生成中间帧，窗口仍按 4K 显示", action: nil, keyEquivalent: "")
        modeInfo.isEnabled = false
        interpolationModeMenu.addItem(modeInfo)
        interpolationModeParent.submenu = interpolationModeMenu
        pictureMenu.addItem(interpolationModeParent)
        frameInterpolationMenuItem = NSMenuItem(title: "插帧（实验·跳过重复帧）", action: #selector(toggleFrameInterpolation(_:)), keyEquivalent: "")
        frameInterpolationMenuItem.target = self
        pictureMenu.addItem(frameInterpolationMenuItem)
        let presentationPacingParent = NSMenuItem(title: "呈现节奏", action: nil, keyEquivalent: "")
        let presentationPacingMenu = NSMenu(title: "呈现节奏")
        presentationPacingMenuItems = PresentationPacingMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.label,
                                  action: #selector(selectPresentationPacing(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = mode == presentationPacingMode ? .on : .off
            presentationPacingMenu.addItem(item)
            return item
        }
        presentationPacingParent.submenu = presentationPacingMenu
        pictureMenu.addItem(presentationPacingParent)
        pictureMenu.addItem(.separator())
        updateAppleLowLatencyMenuAvailability()

        let diagnosticsMenu = NSMenu(title: "诊断")
        let snapshot = NSMenuItem(title: "导出诊断快照", action: #selector(exportDiagnostics(_:)), keyEquivalent: "d")
        snapshot.target = self
        diagnosticsMenu.addItem(snapshot)
        let openLogs = NSMenuItem(title: "打开自动日志文件夹", action: #selector(openDiagnosticLogs(_:)), keyEquivalent: "")
        openLogs.target = self
        diagnosticsMenu.addItem(openLogs)
        let retryMetal = NSMenuItem(title: "重试 Metal 渲染", action: #selector(retryMetal(_:)), keyEquivalent: "r")
        retryMetal.target = self
        diagnosticsMenu.addItem(retryMetal)

        let statusMenu = NSMenu(title: "状态")
        statusTextItem = NSMenuItem(title: "正在连接…", action: nil, keyEquivalent: "")
        statusTextItem.isEnabled = false
        statusMenu.addItem(statusTextItem)
        statusDetailsItem = NSMenuItem(title: "等待视频格式…", action: nil, keyEquivalent: "")
        statusDetailsItem.isEnabled = false
        statusMenu.addItem(statusDetailsItem)

        addTopLevelMenu("采集卡", menu: deviceMenu, to: main)
        addTopLevelMenu("分辨率", menu: formatMenu, to: main)
        addTopLevelMenu("音频", menu: audioMenu, to: main)
        addTopLevelMenu("窗口", menu: windowMenu, to: main)
        addTopLevelMenu("画面", menu: pictureMenu, to: main)
        addTopLevelMenu("诊断", menu: diagnosticsMenu, to: main)
        addTopLevelMenu("状态", menu: statusMenu, to: main)
        NSApp.mainMenu = main
    }

    func addTopLevelMenu(_ title: String, menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }

    // MARK: 窗口

    func windowDidChangeBackingProperties(_ notification: Notification) {
        // 换显示器 / 缩放变化时跟上 DPI
        let s = window?.backingScaleFactor ?? 2.0
        previewView.metalLayer.contentsScale = s
        previewView.fallbackLayer?.contentsScale = s
        previewView.needsLayout = true
    }

    // MARK: 设备插拔（采集卡重插后自动恢复）

    @objc func deviceDisconnected(_ n: Notification) {
        guard let d = n.object as? AVCaptureDevice,
              d.uniqueID == currentVideoDevice?.uniqueID else { return }
        setCaptureDisplayAwake(false, reason: "采集设备断开")
        deviceLost = true
        diagnosticLog.append("采集设备断开; device=\(d.localizedName)")
        setStatus("采集卡已拔出（\(d.localizedName)），重插后自动恢复…", base: false)
    }

    @objc func deviceConnected(_ n: Notification) {
        guard deviceLost,
              let d = n.object as? AVCaptureDevice, d.hasMediaType(.video) else { return }
        deviceLost = false
        diagnosticLog.append("检测到采集设备重新连接; device=\(d.localizedName)")
        setStatus("检测到设备 \(d.localizedName)，正在重连…", base: false)
        // 稍等系统枚举完成再重建
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshDevices(selectPreferred: false)
        }
    }

    @objc func sessionInterrupted(_ n: Notification) {
        diagnosticLog.append("采集会话中断; userInfo=\(n.userInfo ?? [:])")
        setStatus("采集会话中断：重插采集卡或切换分辨率恢复", base: false)
    }

    // MARK: Devices

    func allVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.devices(for: .video)
    }

    func allAudioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.devices(for: .audio)
    }

    func refreshDevices(selectPreferred: Bool) {
        let keepID = devicePopup.selectedItem?.representedObject as? String
            ?? currentVideoDevice?.uniqueID
        devicePopup.removeAllItems()
        let videos = allVideoDevices()
        for d in videos {
            devicePopup.addItem(withTitle: d.localizedName)
            devicePopup.lastItem?.representedObject = d.uniqueID
        }
        if videos.isEmpty {
            updateDeviceMenu()
            setStatus("没找到摄像头/采集卡，检查 USB 连接", base: false)
            return
        }
        // 原选择还在就保留（重插恢复用），否则按偏好选
        if let keep = keepID,
           let idx = videos.firstIndex(where: { $0.uniqueID == keep }) {
            devicePopup.selectItem(at: idx)
        } else {
            let idx = preferredVideoIndex(videos) ?? 0
            devicePopup.selectItem(at: idx)
        }
        updateDeviceMenu()
        rebuildFormatsAndStart()
    }

    func updateDeviceMenu() {
        guard deviceMenu != nil else { return }
        deviceMenu.removeAllItems()
        for index in 0..<devicePopup.numberOfItems {
            let popupItem = devicePopup.item(at: index)!
            let item = NSMenuItem(title: popupItem.title,
                                  action: #selector(selectDeviceFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.representedObject = popupItem.representedObject
            item.state = index == devicePopup.indexOfSelectedItem ? .on : .off
            deviceMenu.addItem(item)
        }
        if deviceMenu.numberOfItems == 0 {
            let empty = NSMenuItem(title: "未发现采集设备", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            deviceMenu.addItem(empty)
        }
    }

    @objc func selectDeviceFromMenu(_ sender: NSMenuItem) {
        guard devicePopup.item(at: sender.tag) != nil else { return }
        devicePopup.selectItem(at: sender.tag)
        updateDeviceMenu()
        deviceChanged(sender)
    }

    func preferredVideoIndex(_ videos: [AVCaptureDevice]) -> Int? {
        let keys = ["ugreen", "95348", "capture", "hdmi", "elgato", "avermedia", "jemdo"]
        for (i, d) in videos.enumerated() {
            let n = (d.localizedName + " " + d.uniqueID).lowercased()
            if keys.contains(where: { n.contains($0) }) { return i }
        }
        // 非 Mac 自带相机的第一个
        for (i, d) in videos.enumerated() {
            let n = d.localizedName
            if !n.contains("MacBook") && !n.contains("桌上视角") && !n.contains("Desk") { return i }
        }
        return 0
    }

    func selectedVideoDevice() -> AVCaptureDevice? {
        guard let id = devicePopup.selectedItem?.representedObject as? String else { return nil }
        return allVideoDevices().first(where: { $0.uniqueID == id })
    }

    func matchingAudioDevice(for video: AVCaptureDevice) -> AVCaptureDevice? {
        let audios = allAudioDevices()
        let vn = video.localizedName.lowercased()
        // 同名音频优先（UGREEN 视频 + UGREEN 音频）
        let short = vn.replacingOccurrences(of: " video", with: "")
            .replacingOccurrences(of: " camera", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let m = audios.first(where: { $0.localizedName.lowercased().contains(short) }) { return m }
        for k in ["ugreen", "95348", "capture", "hdmi", "usb"] {
            if let m = audios.first(where: { ($0.localizedName + $0.uniqueID).lowercased().contains(k) }) { return m }
        }
        return nil
    }

    // MARK: Formats

    /// 在同一 device 实例上按规格重新匹配 format，避免跨实例 Format 导致设置 silently 失效
    func matchFormat(in video: AVCaptureDevice, opt: FormatOption) -> AVCaptureDevice.Format? {
        for f in video.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard dims.width == opt.width, dims.height == opt.height else { continue }
            guard CMFormatDescriptionGetMediaSubType(f.formatDescription) == opt.subtype else { continue }
            let maxFps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            if opt.fps <= maxFps + 0.6 { return f }
        }
        return nil
    }

    /// 设备当前实际生效的格式（跟"请求的"对照用）
    func actualFormatLine(_ video: AVCaptureDevice) -> String {
        let d = CMVideoFormatDescriptionGetDimensions(video.activeFormat.formatDescription)
        let dur = video.activeVideoMinFrameDuration
        let fps = dur.value > 0
            ? String(format: "%.2f", Double(dur.timescale) / Double(dur.value)) : "?"
        return "\(d.width)×\(d.height) @\(fps) · \(codecTag(CMFormatDescriptionGetMediaSubType(video.activeFormat.formatDescription)))"
    }

    // 说明书让选 YUY2：无压缩 4:2:2，兼容性最好，优先排前面
    func codecScore(_ s: FourCharCode) -> Int {
        switch s {
        case kCVPixelFormatType_422YpCbCr8_yuvs: return 0 // YUY2
        case kCVPixelFormatType_422YpCbCr8: return 1      // UYVY
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return 2 // NV12
        default: return 3 // MJPEG 等压缩格式放最后
        }
    }

    func codecTag(_ s: FourCharCode) -> String {
        switch s {
        case kCVPixelFormatType_422YpCbCr8_yuvs: return "YUY2"
        case kCVPixelFormatType_422YpCbCr8: return "UYVY"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "NV12"
        default: return fourccString(s)
        }
    }

    func fourccString(_ f: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((f >> 24) & 0xFF), UInt8((f >> 16) & 0xFF),
                              UInt8((f >> 8) & 0xFF), UInt8(f & 0xFF)]
        if let s = String(bytes: bytes, encoding: .ascii),
           s.allSatisfy({ $0.isLetter || $0.isNumber }) { return s }
        return String(format: "%08X", f)
    }

    func collectFormats(_ device: AVCaptureDevice) -> [FormatOption] {
        var seen = Set<String>()
        var opts: [FormatOption] = []
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            if dims.width < 640 { continue }
            let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let maxFps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            for want in [60.0, 59.94, 50.0, 30.0, 29.97, 25.0].filter({ $0 <= maxFps + 0.6 }) {
                let key = "\(dims.width)x\(dims.height)@\(Int(want))-\(String(format: "%08X", subtype))"
                if seen.contains(key) { continue }
                seen.insert(key)
                opts.append(FormatOption(width: dims.width, height: dims.height, fps: want,
                                         format: f, subtype: subtype,
                                         label: "\(dims.width)×\(dims.height) @\(Int(want)) · \(codecTag(subtype))"))
                break
            }
        }
        // 按分辨率、帧率和 YUY2 优先级排序，让采集卡报告的最高模式显示在前面。
        opts.sort {
            let a = Int($0.width) * Int($0.height), b = Int($1.width) * Int($1.height)
            if a != b { return a > b }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            return codecScore($0.subtype) < codecScore($1.subtype)
        }
        return opts
    }

    func rebuildFormatsAndStart() {
        guard let video = selectedVideoDevice() else { return }
        formatOptions = collectFormats(video)
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: formatOptions.map { $0.label })
        // 优先选择采集卡报告的 4K60；匹配帧率要精确，不能让 4K30 抢先命中。
        var sel = 0
        for (w, f) in [(Int32(3840), 60.0), (Int32(3840), 30.0), (2560, 60.0), (1920, 60.0)] {
            let matches = formatOptions.indices.filter {
                formatOptions[$0].width == w && abs(formatOptions[$0].fps - f) < 1.0
            }
            if let i = matches.first(where: { codecScore(formatOptions[$0].subtype) == 0 })
                ?? matches.first {
                sel = i
                break
            }
        }
        if !formatOptions.isEmpty { formatPopup.selectItem(at: sel) }
        updateFormatMenu()
        diagnosticLog.append("设备/格式列表更新; device=\(video.localizedName); formats=\(formatOptions.map(\.label).joined(separator: "; ")); default=\(formatOptions.indices.contains(sel) ? formatOptions[sel].label : "无")")
        startSession(video: video, formatIndex: sel)
    }

    func updateFormatMenu() {
        guard formatMenu != nil else { return }
        formatMenu.removeAllItems()
        for index in 0..<formatPopup.numberOfItems {
            let popupItem = formatPopup.item(at: index)!
            let item = NSMenuItem(title: popupItem.title,
                                  action: #selector(selectFormatFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == formatPopup.indexOfSelectedItem ? .on : .off
            formatMenu.addItem(item)
        }
        if formatMenu.numberOfItems == 0 {
            let empty = NSMenuItem(title: "当前设备没有可用格式", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            formatMenu.addItem(empty)
        }
    }

    @objc func selectFormatFromMenu(_ sender: NSMenuItem) {
        guard formatPopup.item(at: sender.tag) != nil else { return }
        formatPopup.selectItem(at: sender.tag)
        updateFormatMenu()
        formatChanged(sender)
    }

    // MARK: Session

    func startSession(video: AVCaptureDevice, formatIndex: Int) {
        frameLock.lock()
        frameInterpolationEpoch += 1
        let interpolationEngine = frameInterpolationEngine
        interpolatedFrameCount = 0
        interpolationRepeatedFrameSkipCount = 0
        interpolationFailureCount = 0
        lastInterpolationError = nil
        frameLock.unlock()
        interpolationEngine?.reset()
        let opt = formatOptions.indices.contains(formatIndex) ? formatOptions[formatIndex] : nil
        let requested = opt?.label ?? "未知格式[\(formatIndex)]"
        let initialAudioVolume = isMuted ? Float(0) : audioVolume
        diagnosticLog.append("请求启动采集会话; device=\(video.localizedName); requested=\(requested)")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setCaptureDisplayAwake(false, reason: "重新配置采集会话")
            // 1. 先停流：在运行中切格式会被静默吞掉（之前"请求/实际"对不上的主因）
            if self.session.isRunning { self.session.stopRunning() }
            if let locked = self.lockedFormatDevice {
                locked.unlockForConfiguration()
                self.lockedFormatDevice = nil
                self.diagnosticLog.append("停止旧流并释放设备格式锁; device=\(locked.localizedName)")
            }
            // 重置帧统计
            self.frameLock.lock()
            self.frameCount = 0
            self.droppedCount = 0
            self.inputQueueDropCount = 0
            self.presentationLimitDropCount = 0
            self.rendererFailureCount = 0
            self.exactDuplicateSourceCount = 0
            self.sourceCompareCount = 0
            self.sourceCompareTotalMilliseconds = 0
            self.sourceCompareMaxMilliseconds = 0
            self.lastAcceptedSourceBuffer = nil
            self.consecFails = 0
            self.didLogRenderFailure = false
            self.firstRenderError = nil
            self.lastRenderError = nil
            self.lastSetDesc = nil
            self.setVerifyDesc = nil
            self.lastPixelBuffer = nil
            self.lastPixelFormat = 0
            self.lastWidth = 0
            self.lastHeight = 0
            self.lastFrameDate = nil
            self.interpolatedFrameCount = 0
            self.interpolationRepeatedFrameSkipCount = 0
            self.interpolationFailureCount = 0
            self.lastInterpolationError = nil
            self.tickCount = 0
            self.tickDate = Date()
            self.measuredFps = 0
            self.sessionGeneration += 1
            let gen = self.sessionGeneration
            self.frameLock.unlock()

            // 选定的 AVCaptureDevice.Format 是分辨率/帧率的唯一依据。
            self.session.beginConfiguration()
            // 清掉旧输入输出
            for i in self.session.inputs { self.session.removeInput(i) }
            for o in self.session.outputs { self.session.removeOutput(o) }
            self.audioPreviewOutput = nil
            self.videoDataOutput = nil

            // 视频输入
            do {
                let vin = try AVCaptureDeviceInput(device: video)
                if self.session.canAddInput(vin) { self.session.addInput(vin) }
                self.currentVideoDevice = video
            } catch {
                self.diagnosticLog.append("打开视频设备失败; device=\(video.localizedName); error=\(error.localizedDescription)")
                DispatchQueue.main.async { self.setStatus("打不开视频设备：\(error.localizedDescription)", base: false) }
                self.session.commitConfiguration()
                return
            }

            // 音频输入 + 监听输出
            var audioName = "无"
            if let audio = self.matchingAudioDevice(for: video) {
                do {
                    let ain = try AVCaptureDeviceInput(device: audio)
                    if self.session.canAddInput(ain) { self.session.addInput(ain) }
                    let preview = AVCaptureAudioPreviewOutput()
                    preview.volume = initialAudioVolume
                    if self.session.canAddOutput(preview) {
                        self.session.addOutput(preview)
                        self.audioPreviewOutput = preview
                        self.currentAudioDevice = audio
                        audioName = audio.localizedName
                    }
                } catch {
                    audioName = "音频打开失败"
                }
            }
            // 视频帧截流：要 NV12 原生缓冲，自己用 Metal 做 YUV→RGB，
            // 色彩范围/矩阵可控，比系统预览层准
            let tap = AVCaptureVideoDataOutput()
            tap.alwaysDiscardsLateVideoFrames = true
            tap.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
            tap.setSampleBufferDelegate(self, queue: self.framesQueue)
            if self.session.canAddOutput(tap) {
                self.session.addOutput(tap)
                self.videoDataOutput = tap
            }

            self.session.commitConfiguration()
            self.diagnosticLog.append("采集拓扑已提交; preset=\(self.session.sessionPreset.rawValue); active=\(self.actualFormatLine(video))")

            // OBS 的 macOS 自定义格式路径先恢复默认会话预设，再锁定设备格式。
            // macOS 会在 startRunning 时自动重配输入；设备锁必须一直持有到采集停止。
            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.high) {
                self.session.sessionPreset = .high
            }
            self.session.commitConfiguration()

            if let opt {
                if let match = self.matchFormat(in: video, opt: opt) {
                    self.session.beginConfiguration()
                    do {
                        try video.lockForConfiguration()
                        video.activeFormat = match
                        let ranges = match.videoSupportedFrameRateRanges
                        let near = ranges.sorted { abs($0.maxFrameRate - opt.fps) < abs($1.maxFrameRate - opt.fps) }
                        if let range = near.first(where: { abs($0.maxFrameRate - opt.fps) < 1.0 })
                            ?? near.first(where: { $0.maxFrameRate >= opt.fps - 0.6 })
                            ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                            let wanted = CMTimeMakeWithSeconds(1.0 / opt.fps, preferredTimescale: 60000)
                            var locked = wanted
                            if CMTimeCompare(wanted, range.minFrameDuration) < 0 { locked = range.minFrameDuration }
                            else if CMTimeCompare(wanted, range.maxFrameDuration) > 0 { locked = range.maxFrameDuration }
                            video.activeVideoMinFrameDuration = locked
                            video.activeVideoMaxFrameDuration = locked
                            let fps = locked.value > 0 ? Double(locked.timescale) / Double(locked.value) : 0
                            let dimensions = CMVideoFormatDescriptionGetDimensions(video.activeFormat.formatDescription)
                            self.frameLock.lock()
                            self.lastSetDesc = "\(opt.width)×\(opt.height) \(self.codecTag(opt.subtype)) 锁定 \(String(format: "%.2f", fps))fps"
                            self.setVerifyDesc = "独立格式事务回读 \(dimensions.width)×\(dimensions.height)"
                            self.frameLock.unlock()
                            self.diagnosticLog.append("独立格式事务已设置; requested=\(opt.label); active=\(self.actualFormatLine(video)); range=\(range.minFrameRate)-\(range.maxFrameRate)")
                        } else {
                            self.frameLock.lock()
                            self.setVerifyDesc = "无可用帧率 range"
                            self.frameLock.unlock()
                            self.diagnosticLog.append("目标格式没有帧率范围; requested=\(opt.label)")
                        }
                        self.lockedFormatDevice = video
                        self.session.commitConfiguration()
                        self.diagnosticLog.append("采集期间保持设备格式锁; device=\(video.localizedName)")
                    } catch {
                        self.session.commitConfiguration()
                        self.frameLock.lock()
                        self.setVerifyDesc = "锁定异常：\(error.localizedDescription)"
                        self.frameLock.unlock()
                        self.diagnosticLog.append("独立格式事务设置失败; requested=\(opt.label); error=\(error.localizedDescription)")
                        DispatchQueue.main.async { self.setStatus("设置分辨率失败：\(error.localizedDescription)", base: false) }
                    }
                } else {
                    self.frameLock.lock()
                    self.setVerifyDesc = "未找到匹配格式"
                    self.frameLock.unlock()
                    self.diagnosticLog.append("找不到匹配的采集格式; requested=\(opt.label)")
                    DispatchQueue.main.async { self.setStatus("该格式在当前设备上找不到，未切换", base: false) }
                }
            }
            self.diagnosticLog.append("格式协商配置已完成; method=activeFormat+deviceLock; preset=\(self.session.sessionPreset.rawValue); active=\(self.actualFormatLine(video))")

            // 状态（主线程：先强制布局，保证 drawableSize 就绪再起流）
            DispatchQueue.main.async {
                self.previewView.needsLayout = true
                self.previewView.layoutSubtreeIfNeeded()
                let res = opt.map { "\($0.width)×\($0.height) @\(Int($0.fps)) · \(self.codecTag($0.subtype))" } ?? "?"
                self.setStatus("\(video.localizedName) · \(res) · 音频: \(audioName)")
                self.window.title = "SwitchViewer - \(res)"
            }

            if !self.session.isRunning { self.session.startRunning() }
            self.setCaptureDisplayAwake(self.session.isRunning, reason: "采集会话启动结果")
            self.diagnosticLog.append("会话启动后格式; requested=\(requested); preset=\(self.session.sessionPreset.rawValue); active=\(self.actualFormatLine(video))")

            // 看门狗：区分"没信号"和"有信号但渲染失败"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, gen == self.sessionGeneration else { return }
                self.frameLock.lock()
                let n = self.frameCount
                let d = self.droppedCount
                let err = self.lastRenderError
                let bufferWidth = self.lastWidth
                let bufferHeight = self.lastHeight
                let pixelFormat = self.lastPixelFormat
                let fps = self.measuredFps
                self.frameLock.unlock()
                if n + d == 0 {
                    self.setStatus("未收到视频帧：确认 Switch 点亮 + HDMI 插在采集卡 IN 口，或换个分辨率/格式试试", base: false)
                } else if n == 0 {
                    self.setStatus("有信号但 Metal 渲染失败（\(err ?? "?")），已切回系统预览", base: false)
                } else if let opt {
                    if bufferWidth != Int(opt.width) || bufferHeight != Int(opt.height) {
                        self.diagnosticLog.append("采集帧尺寸与请求不一致; requested=\(opt.width)x\(opt.height); buffer=\(bufferWidth)x\(bufferHeight); active=\(self.actualFormatLine(video))")
                        self.setStatus("分辨率未匹配：请求 \(opt.width)×\(opt.height)，实际收到 \(bufferWidth)×\(bufferHeight)", base: false)
                    } else {
                        self.setStatus("实际画面：\(bufferWidth)×\(bufferHeight) · \(self.codecTag(pixelFormat)) · \(String(format: "%.1f", fps))fps")
                    }
                }
            }
        }
    }

    // MARK: Actions

    @objc func deviceChanged(_ sender: Any) {
        updateDeviceMenu()
        rebuildFormatsAndStart()
    }

    @objc func formatChanged(_ sender: Any) {
        guard let video = selectedVideoDevice() else { return }
        let index = formatPopup.indexOfSelectedItem
        updateFormatMenu()
        let requested = formatOptions.indices.contains(index) ? formatOptions[index].label : "未知格式[\(index)]"
        diagnosticLog.append("用户切换分辨率; device=\(video.localizedName); requested=\(requested)")
        startSession(video: video, formatIndex: index)
    }

    @objc func toggleMute(_ sender: Any) {
        isMuted.toggle()
        muteMenuItem.state = isMuted ? .on : .off
        let newVolume = isMuted ? Float(0) : audioVolume
        sessionQueue.async { [weak self] in
            self?.audioPreviewOutput?.volume = newVolume
        }
    }

    @objc func volumeChanged(_ sender: Any) {
        audioVolume = Float(volumeSlider.doubleValue)
        if isMuted {
            isMuted = false
            muteMenuItem.state = .off
        }
        let v = audioVolume
        sessionQueue.async { [weak self] in self?.audioPreviewOutput?.volume = v }
    }

    @objc func goFullscreen(_ sender: Any) { window.toggleFullScreen(nil) }

    @objc func toggleFloat(_ sender: Any) {
        isAlwaysOnTop.toggle()
        floatMenuItem.state = isAlwaysOnTop ? .on : .off
        window.level = isAlwaysOnTop ? .floating : .normal
    }

    @objc func cycleColor(_ sender: Any) {
        guard let r = renderer else { return }
        let next = ColorMode(rawValue: (r.colorMode.rawValue + 1) % ColorMode.allCases.count)!
        applyColorMode(next)
    }

    @objc func selectColorMode(_ sender: NSMenuItem) {
        guard let mode = ColorMode(rawValue: sender.tag) else { return }
        applyColorMode(mode)
    }

    @objc func selectFrameInterpolationMode(_ sender: NSMenuItem) {
        guard let mode = FrameInterpolationMode(rawValue: sender.tag) else { return }
        if mode == .appleLowLatency || mode == .appleLowLatency4KProxy {
            frameLock.lock()
            let width = lastWidth
            let height = lastHeight
            let pixelFormat = lastPixelFormat
            frameLock.unlock()
            let available = mode == .appleLowLatency
                ? canUseAppleLowLatencyFrame(width: width, height: height, pixelFormat: pixelFormat)
                : canUseAppleLowLatency4KProxy(width: width, height: height, pixelFormat: pixelFormat)
            guard available else {
                updateAppleLowLatencyMenuAvailability()
                setStatus(mode == .appleLowLatency
                    ? "Apple 原生低延迟插帧需要 1920×1080 NV12 输入"
                    : "Apple 4K 代理插帧需要 3840×2160 NV12 输入", base: false)
                return
            }
        }
        frameInterpolationMode = mode
        for item in frameInterpolationModeMenuItems {
            item.state = item.tag == mode.rawValue ? .on : .off
        }
        frameInterpolationEngine?.setMode(mode)
        diagnosticLog.append("插帧方式切换; mode=\(mode.label)")
        setStatus("插帧方式：\(mode.label)", base: false)
    }

    @objc func selectPresentationPacing(_ sender: NSMenuItem) {
        guard let mode = PresentationPacingMode(rawValue: sender.tag) else { return }
        frameLock.lock()
        presentationPacingMode = mode
        frameLock.unlock()
        for item in presentationPacingMenuItems {
            item.state = item.tag == mode.rawValue ? .on : .off
        }
        diagnosticLog.append("呈现节奏切换; mode=\(mode.label)")
        setStatus("呈现节奏：\(mode.label)", base: false)
    }

    func updateAppleLowLatencyMenuAvailability() {
        frameLock.lock()
        let width = lastWidth
        let height = lastHeight
        let pixelFormat = lastPixelFormat
        frameLock.unlock()
        for item in frameInterpolationModeMenuItems {
            switch FrameInterpolationMode(rawValue: item.tag) {
            case .appleLowLatency:
                item.isEnabled = canUseAppleLowLatencyFrame(width: width, height: height,
                                                            pixelFormat: pixelFormat)
            case .appleLowLatency4KProxy:
                item.isEnabled = canUseAppleLowLatency4KProxy(width: width, height: height,
                                                              pixelFormat: pixelFormat)
            default:
                break
            }
        }
    }

    func applyColorMode(_ mode: ColorMode) {
        renderer?.colorMode = mode
        for item in colorMenuItems { item.state = item.tag == mode.rawValue ? .on : .off }
        setStatus("色彩模式：\(mode.label)", base: false)
    }

    @objc func toggleFrameInterpolation(_ sender: Any) {
        guard fallbackLayer == nil else {
            setStatus("插帧需要 Metal 渲染；当前正在使用系统预览", base: false)
            return
        }
        frameLock.lock()
        let wasEnabled = frameInterpolationEnabled
        let isUnavailable = frameInterpolationUnavailable
        frameLock.unlock()
        let shouldEnable = !wasEnabled
        if shouldEnable && isUnavailable {
            setStatus("插帧处理器已失败并停用；请重启 app 后再试", base: false)
            return
        }
        var newEngine: FrameInterpolationEngine?
        if shouldEnable {
            if #available(macOS 26.0, *) {
                newEngine = frameInterpolationEngine ?? AdaptiveFrameInterpolator(
                    onRepeatedGameFrameSkipped: { [weak self] in
                        guard let self else { return }
                        self.frameLock.lock()
                        self.interpolationRepeatedFrameSkipCount += 1
                        self.frameLock.unlock()
                    },
                    onQueuedFramesDropped: { [weak self] count in
                        guard let self else { return }
                        self.frameLock.lock()
                        self.droppedCount += count
                        self.inputQueueDropCount += count
                        self.frameLock.unlock()
                    },
                    onBackendChanged: { [weak self] backend in
                        self?.diagnosticLog.append("插帧后端切换; backend=\(backend)")
                    },
                    onTimingReport: { [weak self] report in
                        self?.diagnosticLog.append(report)
                    })
                newEngine?.setMode(frameInterpolationMode)
            } else {
                setStatus("系统插帧需要 macOS 26 或更新版本", base: false)
                return
            }
        }

        frameLock.lock()
        if let newEngine { frameInterpolationEngine = newEngine }
        frameInterpolationEnabled = shouldEnable
        frameInterpolationEpoch += 1
        lastAcceptedSourceBuffer = nil
        frameInterpolationMenuItem.state = shouldEnable ? .on : .off
        let activeEngine = frameInterpolationEngine
        frameLock.unlock()
        activeEngine?.reset()

        let message = shouldEnable
            ? "实验性插帧已开启（\(frameInterpolationMode.label)，自动跳过重复游戏帧）"
            : "实验性插帧已关闭"
        diagnosticLog.append("帧插值开关; enabled=\(shouldEnable); mode=\(frameInterpolationMode.label)")
        setStatus(message, base: false)
    }

    func setStatus(_ s: String, base: Bool = true) {
        diagnosticLog.append("状态; \(s)")
        if base {
            baseStatus = s
            isBaseStatus = true
            if measuredFps > 0.5 {
                statusTextItem.title = "\(s) · \(String(format: "%.0f", measuredFps))fps"
            } else {
                statusTextItem.title = s
            }
        } else {
            isBaseStatus = false
            statusTextItem.title = s
        }
        refreshStatusDetails()
    }

    func refreshStatusDetails() {
        guard statusDetailsItem != nil else { return }
        let device = currentVideoDevice?.localizedName ?? "无采集卡"
        let format = currentVideoDevice.map(actualFormatLine) ?? "等待视频格式…"
        let fps = measuredFps > 0 ? String(format: "%.1f fps", measuredFps) : "等待画面"
        statusDetailsItem.title = "\(device) · \(format) · \(fps)"
    }

    @objc func tickFps() {
        frameLock.lock()
        let c = frameCount
        let lastAge = lastFrameDate.map { Date().timeIntervalSince($0) } ?? .infinity
        frameLock.unlock()
        let now = Date()
        let dt = now.timeIntervalSince(tickDate)
        if dt > 0.5 {
            if c < tickCount {
                // 刚切换过格式，计数器已重置，丢弃这次瞬时值
                tickCount = c
                tickDate = now
                return
            }
            if c != tickCount {
                measuredFps = Double(c - tickCount) / dt
                tickCount = c
                tickDate = now
                if isBaseStatus {
                    statusTextItem.title = "\(baseStatus) · \(String(format: "%.0f", measuredFps))fps"
                }
                refreshStatusDetails()
            } else if lastAge > 3 {
                // 流断了：fps 归零
                measuredFps = 0
                tickDate = now
                refreshStatusDetails()
            }
        }
    }

    // MARK: 截图 + 诊断

    @objc func takeScreenshot(_ sender: Any) {
        frameLock.lock()
        let pb = lastPixelBuffer
        let n = frameCount
        frameLock.unlock()
        guard let pb = pb else {
            setStatus("存不了：还没收到视频帧（已收 \(n) 帧），先解决黑屏", base: false)
            return
        }
        let ci = CIImage(cvPixelBuffer: pb)
        let screenshotCI: CIImage
        if CVPixelBufferGetWidth(pb) == 1920, CVPixelBufferGetHeight(pb) == 1080 {
            let scaler = CIFilter(name: "CILanczosScaleTransform")
            scaler?.setValue(ci, forKey: kCIInputImageKey)
            scaler?.setValue(2.0, forKey: kCIInputScaleKey)
            scaler?.setValue(1.0, forKey: kCIInputAspectRatioKey)
            screenshotCI = scaler?.outputImage
                ?? ci.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        } else {
            screenshotCI = ci
        }
        let rep = NSCIImageRep(ciImage: screenshotCI)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        guard let tiff = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let png = bmp.representation(using: .png, properties: [:]) else {
            setStatus("截图转换失败", base: false)
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwitchViewer-\(fmt.string(from: Date())).png")
        do {
            try png.write(to: url)
            setStatus("截图已存：\(url.path)（已收 \(n) 帧）", base: false)
        } catch {
            setStatus("截图保存失败：\(error.localizedDescription)", base: false)
        }
    }

    @objc func exportDiagnostics(_ sender: Any) {
        frameLock.lock()
        let n = frameCount
        let d = droppedCount
        let first = firstRenderError
        let pf = lastPixelFormat
        let lw = lastWidth
        let lh = lastHeight
        let err = lastRenderError
        let setD = lastSetDesc
        let setV = setVerifyDesc
        let age = lastFrameDate.map { -Int($0.timeIntervalSinceNow) }
        let gen = sessionGeneration
        let interpolationEnabled = frameInterpolationEnabled
        let interpolatedFrames = interpolatedFrameCount
        let repeatedFrameSkips = interpolationRepeatedFrameSkipCount
        let interpolationFailures = interpolationFailureCount
        let interpolationError = lastInterpolationError ?? "无"
        frameLock.unlock()
        let sel = formatPopup.indexOfSelectedItem
        var lines: [String] = []
        lines.append("SwitchViewer 诊断 \(Date())")
        lines.append("视频: \(currentVideoDevice?.localizedName ?? "无")")
        lines.append("音频: \(currentAudioDevice?.localizedName ?? "无")")
        lines.append("渲染: Metal 自管 YUV→RGB，色彩模式: \(renderer?.colorMode.label ?? "无")")
        lines.append("Metal 初始化: \(metalInitError ?? "OK")，自检: \(metalSelfTest ?? "通过")")
        lines.append("回退预览: \(fallbackLayer == nil ? "否" : "是")")
        let ml = previewView.metalLayer
        lines.append("metalLayer frame=\(Int(ml.frame.width))x\(Int(ml.frame.height)) drawable=\(Int(ml.drawableSize.width))x\(Int(ml.drawableSize.height)) hidden=\(ml.isHidden) attached=\(ml.superlayer != nil) inWin=\(previewView.window != nil) dev=\(ml.device != nil)")
        lines.append("session 运行中: \(session.isRunning)，配置代次: \(gen)")
        lines.append("AVCaptureSession 预设: \(session.sessionPreset.rawValue)")
        lines.append("渲染成功帧: \(n)，渲染失败/丢帧: \(d)，实测fps: \(String(format: "%.1f", measuredFps))")
        lines.append("插帧: \(interpolationEnabled ? "开启" : "关闭")，方式: \(frameInterpolationMode.label)，成功插入: \(interpolatedFrames)，重复游戏帧跳过: \(repeatedFrameSkips)，失败: \(interpolationFailures)，最近错误: \(interpolationError)")
        lines.append("首次渲染失败原因: \(first ?? "无")")
        lines.append("最近渲染失败原因: \(err ?? "无")")
        lines.append("收到缓冲格式: \(pf == 0 ? "无" : fourccString(pf))，上一帧距今: \(age.map { "\($0)s" } ?? "无帧")")
        lines.append("当前选项 [\(sel)]: \(formatOptions.indices.contains(sel) ? formatOptions[sel].label : "无")")
        lines.append("上次设置: \(setD ?? "无")")
        lines.append("设置即时回读: \(setV ?? "无")")
        lines.append("设备实际格式: \(currentVideoDevice.map(actualFormatLine) ?? "无")")
        lines.append("收到缓冲尺寸: \(lw)x\(lh)")
        lines.append("--- 可选格式 ---")
        for (i, o) in formatOptions.enumerated() {
            lines.append("\(i == sel ? "*" : " ") [\(i)] \(o.label) fourcc=\(fourccString(o.subtype))")
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwitchViewer-诊断-\(fmt.string(from: Date())).txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            setStatus("诊断已导出：\(url.path)，把截图 + 这个文件发我就行", base: false)
        } catch {
            setStatus("诊断导出失败：\(error.localizedDescription)", base: false)
        }
    }

    // MARK: Keys

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": self.goFullscreen(event); return nil
            case "s": self.takeScreenshot(event); return nil
            case "d": self.exportDiagnostics(event); return nil
            case "c": self.cycleColor(event); return nil
            case "r": self.retryMetal(event); return nil
            case "m":
                self.toggleMute(event); return nil
            case "1", "2", "3", "4":
                let i = Int(event.charactersIgnoringModifiers!)! - 1
                if self.formatPopup.numberOfItems > i {
                    self.formatPopup.selectItem(at: i)
                    self.formatChanged(event)
                }
                return nil
            default: return event
            }
        }
    }
}

// MARK: - 帧回调（Metal 渲染 + 统计）

extension AppDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
    func hostTime(forCaptureTimestamp timestamp: CMTime) -> CFTimeInterval? {
        guard CMTimeGetSeconds(timestamp).isFinite,
              let captureClock = session.synchronizationClock else { return nil }
        let hostTimestamp = CMSyncConvertTime(timestamp,
                                              from: captureClock,
                                              to: CMClockGetHostTimeClock())
        let seconds = CMTimeGetSeconds(hostTimestamp)
        return seconds.isFinite ? seconds : nil
    }

    func recordDisplayPresentation(_ frame: PresentationFrame, presentedTime: CFTimeInterval) {
        let wasPresented = presentedTime.isFinite && presentedTime > 0
        let timing = frame.timing
        let sample = DisplayLatencySample(
            isInterpolated: frame.isInterpolated,
            callbackToDisplayMilliseconds: wasPresented
                ? timing.callbackToDisplayMilliseconds(presentedTime) : nil,
            mediaTimestampToDisplayMilliseconds: wasPresented
                ? frame.presentationTimestampHostTime.map { (presentedTime - $0) * 1_000 } : nil,
            callbackToReadyMilliseconds: timing.callbackToReadyMilliseconds(),
            readyToPresentationEnqueueMilliseconds: timing.milliseconds(from: .processingReady,
                                                                       to: .presentationEnqueued),
            presentationQueueWaitMilliseconds: timing.milliseconds(from: .presentationEnqueued,
                                                                   to: .presentationQueueStarted),
            queueStartToDrawableMilliseconds: timing.milliseconds(from: .presentationQueueStarted,
                                                                  to: .drawableAcquired),
            drawableWaitMilliseconds: timing.milliseconds(from: .drawableWaitStarted,
                                                          to: .drawableAcquired),
            drawableToCommitMilliseconds: timing.milliseconds(from: .drawableAcquired,
                                                              to: .commandBufferSubmitStarted),
            gpuSubmitToCompleteMilliseconds: timing.milliseconds(from: .commandBufferSubmitStarted,
                                                                to: .gpuCompleted),
            gpuCompleteToDisplayMilliseconds: wasPresented
                ? timing.milliseconds(from: .gpuCompleted, toHostTime: presentedTime) : nil)
        displayTimingQueue.async {
            self.displayTimingSamples.append(sample)
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastDisplayTimingReportUptime >= 3,
                  !self.displayTimingSamples.isEmpty else { return }
            let samples = self.displayTimingSamples
            self.displayTimingSamples.removeAll(keepingCapacity: true)
            self.lastDisplayTimingReportUptime = now

            func percentile(_ values: [Double], _ fraction: Double) -> Double? {
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                let index = min(sorted.count - 1,
                                max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
                return sorted[index]
            }
            func range(_ values: [Double]) -> String {
                guard let p50 = percentile(values, 0.50),
                      let p95 = percentile(values, 0.95) else { return "无" }
                return String(format: "%.1f/%.1f", p50, p95)
            }
            func stageRange(_ keyPath: KeyPath<DisplayLatencySample, Double?>,
                            in values: [DisplayLatencySample]) -> String {
                range(values.compactMap { $0[keyPath: keyPath] })
            }

            for isInterpolated in [true, false] {
                let group = samples.filter { $0.isInterpolated == isInterpolated }
                guard !group.isEmpty else { continue }
                let shown = group.filter { $0.callbackToDisplayMilliseconds != nil }
                let callbackLatency = shown.compactMap(\.callbackToDisplayMilliseconds)
                let mediaLatency = shown.compactMap(\.mediaTimestampToDisplayMilliseconds)
                self.diagnosticLog.append(
                    "实际上屏分段 P50/P95 ms; frame=\(isInterpolated ? "插值帧" : "采集帧"); samples=\(group.count); presented=\(shown.count); callbackToDisplay=\(range(callbackLatency)); mediaTimestampToDisplay=\(range(mediaLatency)); callbackToReady=\(stageRange(\.callbackToReadyMilliseconds, in: group)); readyToEnqueue=\(stageRange(\.readyToPresentationEnqueueMilliseconds, in: group)); presentationQueueWait=\(stageRange(\.presentationQueueWaitMilliseconds, in: group)); queueStartToDrawable(includesNextDrawableWait)=\(stageRange(\.queueStartToDrawableMilliseconds, in: group)); nextDrawableWait=\(stageRange(\.drawableWaitMilliseconds, in: group)); drawableToSubmit=\(stageRange(\.drawableToCommitMilliseconds, in: group)); gpuSubmitToComplete=\(stageRange(\.gpuSubmitToCompleteMilliseconds, in: group)); gpuCompleteToDisplay=\(stageRange(\.gpuCompleteToDisplayMilliseconds, in: group))")
            }
        }
    }

    private func recordCaptureCallbackTiming(ptsToCallbackMilliseconds: Double?,
                                             callbackWorkMilliseconds: Double) {
        captureCallbackTimingQueue.async {
            self.captureCallbackTimingSamples.append(CaptureCallbackTimingSample(
                ptsToCallbackMilliseconds: ptsToCallbackMilliseconds,
                callbackWorkMilliseconds: callbackWorkMilliseconds))
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastCaptureCallbackTimingReportUptime >= 3,
                  !self.captureCallbackTimingSamples.isEmpty else { return }
            let samples = self.captureCallbackTimingSamples
            self.captureCallbackTimingSamples.removeAll(keepingCapacity: true)
            self.lastCaptureCallbackTimingReportUptime = now

            func percentile(_ values: [Double], _ fraction: Double) -> Double? {
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                let index = min(sorted.count - 1,
                                max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
                return sorted[index]
            }
            func range(_ values: [Double]) -> String {
                guard let p50 = percentile(values, 0.50),
                      let p95 = percentile(values, 0.95) else { return "无" }
                return String(format: "%.1f/%.1f", p50, p95)
            }
            self.diagnosticLog.append(
                "采集回调耗时 P50/P95 ms; samples=\(samples.count); ptsToCallback=\(range(samples.compactMap(\.ptsToCallbackMilliseconds))); callbackWork=\(range(samples.map(\.callbackWorkMilliseconds)))")
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let callbackWorkStart = ProcessInfo.processInfo.systemUptime
        var ptsToCallbackMilliseconds: Double?
        defer {
            let callbackWorkMilliseconds = (ProcessInfo.processInfo.systemUptime - callbackWorkStart) * 1_000
            recordCaptureCallbackTiming(ptsToCallbackMilliseconds: ptsToCallbackMilliseconds,
                                        callbackWorkMilliseconds: callbackWorkMilliseconds)
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureCallbackHostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let presentationTimestampHostTime = hostTime(forCaptureTimestamp: presentationTimeStamp)
        if let presentationTimestampHostTime,
           captureCallbackHostTime >= presentationTimestampHostTime {
            ptsToCallbackMilliseconds = (captureCallbackHostTime - presentationTimestampHostTime) * 1_000
        }
        let pf = CVPixelBufferGetPixelFormatType(pb)
        frameLock.lock()
        let changed = lastWidth != CVPixelBufferGetWidth(pb)
            || lastHeight != CVPixelBufferGetHeight(pb)
            || lastPixelFormat != pf
        lastPixelFormat = pf
        lastWidth = CVPixelBufferGetWidth(pb)
        lastHeight = CVPixelBufferGetHeight(pb)
        lastFrameDate = Date()
        let interpolationEnabled = frameInterpolationEnabled
        let interpolationEngine = frameInterpolationEngine
        let epoch = frameInterpolationEpoch
        frameLock.unlock()
        if changed {
            diagnosticLog.append("收到视频帧格式变化; buffer=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)); pixelFormat=\(fourccString(pf))")
            DispatchQueue.main.async {
                self.updateAppleLowLatencyMenuAvailability()
                if self.frameInterpolationMode == .appleLowLatency
                    || self.frameInterpolationMode == .appleLowLatency4KProxy {
                    self.frameLock.lock()
                    let interpolationEnabled = self.frameInterpolationEnabled
                    let width = self.lastWidth
                    let height = self.lastHeight
                    let pixelFormat = self.lastPixelFormat
                    self.frameLock.unlock()
                    let available = self.frameInterpolationMode == .appleLowLatency
                        ? canUseAppleLowLatencyFrame(width: width, height: height, pixelFormat: pixelFormat)
                        : canUseAppleLowLatency4KProxy(width: width, height: height, pixelFormat: pixelFormat)
                    if interpolationEnabled && !available {
                        self.setStatus(self.frameInterpolationMode == .appleLowLatency
                            ? "Apple 原生低延迟插帧只接受 1920×1080 NV12；当前分辨率按原帧显示"
                            : "Apple 4K 代理插帧只接受 3840×2160 NV12；当前分辨率按原帧显示",
                                       base: false)
                    }
                }
            }
        }
        if interpolationEnabled, let interpolationEngine {
            interpolationEngine.submit(pb,
                                       presentationTimeStamp: presentationTimeStamp) {
                [weak self] generated, source, error, halfInterval in
                guard let self else { return }
                if let error, self.canPresentFrame(epoch: epoch, requireInterpolation: true) {
                    self.recordInterpolationFailure(error)
                }
                self.enqueueInterpolatedFrames(generated: generated, source: source,
                                               sourcePresentationTimeStamp: presentationTimeStamp,
                                               sourceTimestampHostTime: presentationTimestampHostTime,
                                               captureCallbackHostTime: captureCallbackHostTime,
                                               halfInterval: halfInterval, epoch: epoch)
            }
        } else {
            enqueuePresentationFrames([
                PresentationFrame(pixelBuffer: pb, isInterpolated: false,
                                  minimumPresentationDuration: nil,
                                  presentationTimestampHostTime: presentationTimestampHostTime,
                                  timing: PresentationFrameTiming(
                                    captureCallbackHostTime: captureCallbackHostTime))
            ], epoch: epoch, requireInterpolation: false)
        }
    }

    func enqueueInterpolatedFrames(generated: CVPixelBuffer?, source: CVPixelBuffer,
                                   sourcePresentationTimeStamp: CMTime,
                                   sourceTimestampHostTime: CFTimeInterval?,
                                   captureCallbackHostTime: CFTimeInterval,
                                   halfInterval: TimeInterval?, epoch: Int) {
        var frames: [PresentationFrame] = []
        frameLock.lock()
        let pacingMode = presentationPacingMode
        frameLock.unlock()
        let minimumPresentationDuration = pacingMode.minimumDuration(for: halfInterval)
        let processingReadyHostTime = ProcessInfo.processInfo.systemUptime
        if let generated {
            let generatedPresentationTimeStamp: CMTime
            if let halfInterval, halfInterval > 0 {
                generatedPresentationTimeStamp = CMTimeSubtract(
                    sourcePresentationTimeStamp,
                    CMTime(seconds: halfInterval, preferredTimescale: 60_000))
            } else {
                generatedPresentationTimeStamp = sourcePresentationTimeStamp
            }
            frames.append(PresentationFrame(
                pixelBuffer: generated,
                isInterpolated: true,
                minimumPresentationDuration: minimumPresentationDuration,
                presentationTimestampHostTime: hostTime(forCaptureTimestamp: generatedPresentationTimeStamp),
                timing: PresentationFrameTiming(
                    captureCallbackHostTime: captureCallbackHostTime,
                    processingReadyHostTime: processingReadyHostTime)))
        }
        frames.append(PresentationFrame(pixelBuffer: source, isInterpolated: false,
                                        minimumPresentationDuration: generated == nil
                                            ? nil : minimumPresentationDuration,
                                        presentationTimestampHostTime: sourceTimestampHostTime,
                                        timing: PresentationFrameTiming(
                                            captureCallbackHostTime: captureCallbackHostTime,
                                            processingReadyHostTime: processingReadyHostTime)))
        enqueuePresentationFrames(frames, epoch: epoch, requireInterpolation: true)
    }

    func enqueuePresentationFrames(_ frames: [PresentationFrame],
                                  epoch: Int, requireInterpolation: Bool) {
        guard canPresentFrame(epoch: epoch, requireInterpolation: requireInterpolation) else { return }
        var candidates = frames
        if requireInterpolation,
           let sourceFrame = frames.first(where: { !$0.isInterpolated }) {
            frameLock.lock()
            let previousSource = lastAcceptedSourceBuffer
            frameLock.unlock()
            if let previousSource {
                let compareStart = ProcessInfo.processInfo.systemUptime
                let isIdentical = pixelBuffersHaveIdenticalPixels(previousSource, sourceFrame.pixelBuffer)
                let compareMilliseconds = (ProcessInfo.processInfo.systemUptime - compareStart) * 1_000
                frameLock.lock()
                sourceCompareCount += 1
                sourceCompareTotalMilliseconds += compareMilliseconds
                sourceCompareMaxMilliseconds = max(sourceCompareMaxMilliseconds, compareMilliseconds)
                if isIdentical { exactDuplicateSourceCount += 1 }
                frameLock.unlock()
                if isIdentical {
                    // The layer keeps the last drawable visible. Only suppress a source
                    // frame after proving every active NV12 plane byte is unchanged;
                    // 60Hz HUD/UI changes therefore still reach the screen.
                    candidates.removeAll { !$0.isInterpolated }
                }
            }
        }
        guard !candidates.isEmpty else { return }
        var admitted: [PresentationFrame] = []
        for frame in candidates {
            if presentationSlots.wait(timeout: .now()) == .success {
                admitted.append(frame)
            } else {
                break
            }
        }
        if candidates.count == 2, admitted.count == 1, admitted[0].isInterpolated {
            admitted[0] = candidates[1]
        }
        let omittedCount = candidates.count - admitted.count
        if omittedCount > 0 {
            frameLock.lock()
            droppedCount += omittedCount
            presentationLimitDropCount += omittedCount
            frameLock.unlock()
        }
        if admitted.isEmpty { return }
        if let source = admitted.last(where: { !$0.isInterpolated }) {
            frameLock.lock()
            lastAcceptedSourceBuffer = source.pixelBuffer
            frameLock.unlock()
        }
        for frame in admitted { frame.timing.mark(.presentationEnqueued) }
        presentationQueue.async {
            guard self.canPresentFrame(epoch: epoch, requireInterpolation: requireInterpolation) else {
                for _ in admitted { self.presentationSlots.signal() }
                return
            }
            for frame in admitted {
                frame.timing.mark(.presentationQueueStarted)
                self.presentPixelBuffer(frame,
                                       epoch: epoch, requireInterpolation: requireInterpolation,
                                       onPresented: { self.presentationSlots.signal() })
            }
        }
    }

    private func pixelBuffersHaveIdenticalPixels(_ first: CVPixelBuffer,
                                                 _ second: CVPixelBuffer) -> Bool {
        if first === second { return true }
        guard CVPixelBufferGetWidth(first) == CVPixelBufferGetWidth(second),
              CVPixelBufferGetHeight(first) == CVPixelBufferGetHeight(second),
              CVPixelBufferGetPixelFormatType(first) == CVPixelBufferGetPixelFormatType(second),
              CVPixelBufferGetPlaneCount(first) == 2,
              CVPixelBufferGetPlaneCount(second) == 2 else { return false }
        let firstMatrix = CVBufferCopyAttachment(first, kCVImageBufferYCbCrMatrixKey, nil) as? String
        let secondMatrix = CVBufferCopyAttachment(second, kCVImageBufferYCbCrMatrixKey, nil) as? String
        guard firstMatrix == secondMatrix else { return false }

        guard CVPixelBufferLockBaseAddress(first, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly) }
        guard CVPixelBufferLockBaseAddress(second, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(second, .readOnly) }

        for plane in 0..<2 {
            guard let firstBase = CVPixelBufferGetBaseAddressOfPlane(first, plane),
                  let secondBase = CVPixelBufferGetBaseAddressOfPlane(second, plane) else { return false }
            let firstStride = CVPixelBufferGetBytesPerRowOfPlane(first, plane)
            let secondStride = CVPixelBufferGetBytesPerRowOfPlane(second, plane)
            let rows = CVPixelBufferGetHeightOfPlane(first, plane)
            guard firstStride == secondStride,
                  rows == CVPixelBufferGetHeightOfPlane(second, plane) else { return false }
            let byteCount = firstStride * rows
            if Darwin.memcmp(firstBase, secondBase, byteCount) != 0 { return false }
        }
        return true
    }

    func canPresentFrame(epoch: Int, requireInterpolation: Bool) -> Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return frameInterpolationEpoch == epoch
            && (!requireInterpolation || frameInterpolationEnabled)
    }

    func recordInterpolationFailure(_ message: String) {
        frameLock.lock()
        interpolationFailureCount += 1
        let shouldLog = lastInterpolationError != message
        lastInterpolationError = message
        let shouldDisable = frameInterpolationEnabled
        if shouldDisable {
            frameInterpolationEnabled = false
            frameInterpolationEpoch += 1
            frameInterpolationUnavailable = true
        }
        let interpolationEngine = frameInterpolationEngine
        frameLock.unlock()
        if shouldLog { diagnosticLog.append("插帧失败; error=\(message)") }
        if shouldDisable {
            interpolationEngine?.reset()
            DispatchQueue.main.async {
                self.frameInterpolationMenuItem?.state = .off
                self.frameInterpolationMenuItem?.title = "插帧不可用（已自动关闭）"
                self.frameInterpolationMenuItem?.isEnabled = false
                self.setStatus("VideoToolbox 插帧失败，已自动关闭：\(message)", base: false)
            }
        }
    }

    func presentPixelBuffer(_ frame: PresentationFrame,
                            epoch: Int, requireInterpolation: Bool,
                            onPresented: @escaping () -> Void) {
        guard canPresentFrame(epoch: epoch, requireInterpolation: requireInterpolation) else {
            onPresented()
            return
        }
        guard let r = renderer else {
            frameLock.lock()
            droppedCount += 1
            rendererFailureCount += 1
            let errorMessage = "Metal 未初始化：\(metalInitError ?? "?")"
            let firstError = !didLogRenderFailure
            if firstError {
                didLogRenderFailure = true
                if firstRenderError == nil { firstRenderError = errorMessage }
                lastRenderError = errorMessage
            }
            frameLock.unlock()
            if firstError { diagnosticLog.append("渲染错误; \(errorMessage)") }
            onPresented()
            return
        }
        let (ok, err) = r.render(pixelBuffer: frame.pixelBuffer,
                                 minimumPresentationDuration: frame.minimumPresentationDuration,
                                 onPresented: { [weak self] presentedTime in
            self?.recordDisplayPresentation(frame, presentedTime: presentedTime)
            onPresented()
        },
                                 onDrawableWaitStarted: {
            frame.timing.mark(.drawableWaitStarted)
        },
                                 onDrawableAcquired: {
            frame.timing.mark(.drawableAcquired)
        },
                                 onCommandBufferCommitted: {
            frame.timing.mark(.commandBufferSubmitStarted)
        },
                                 onGPUCompleted: {
            frame.timing.mark(.gpuCompleted)
        })
        frameLock.lock()
        if ok {
            lastPixelBuffer = frame.pixelBuffer
            frameCount += 1
            if frame.isInterpolated { interpolatedFrameCount += 1 }
            consecFails = 0
        } else {
            droppedCount += 1
            rendererFailureCount += 1
            consecFails += 1
            let firstError = !didLogRenderFailure
            if firstError {
                didLogRenderFailure = true
                firstRenderError = err
            }
            lastRenderError = err
            let cf = consecFails
            frameLock.unlock()
            if firstError { diagnosticLog.append("Metal 渲染失败; error=\(err ?? "未知"); consecutiveFailures=\(cf)") }
            if cf == 30 { enableFallback(err ?? "未知错误") }
            onPresented()
            return
        }
        frameLock.unlock()
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
