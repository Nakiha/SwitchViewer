import AppKit
import Metal
import QuartzCore

// Fixture-only offscreen producer isolates rendering/copying from a second
// native onscreen presentation. It never replaces a real game's drawable.
final class ScratchDrawable: NSObject, CAMetalDrawable {
    let texture: MTLTexture
    let layer: CAMetalLayer
    var presentedTime: CFTimeInterval { 0 }
    var drawableID: Int { 0 }
    init(texture: MTLTexture, layer: CAMetalLayer) { self.texture = texture; self.layer = layer }
    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {}
}

final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let layer = CAMetalLayer()
    var timer: Timer?
    var queue: MTLCommandQueue!
    var count = 0
    private struct CadenceProfile: Decodable { let intervalsSeconds: [Double] }
    private let replayIntervals: [Double]? = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--cadence=") }) else { return nil }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: String(argument.dropFirst(10))))
            let intervals = try JSONDecoder().decode(CadenceProfile.self, from: data).intervalsSeconds
            guard !intervals.isEmpty, intervals.count <= 100_000,
                  intervals.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 2 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return intervals
        } catch {
            fputs("Invalid cadence profile: \(error)\n", stderr)
            exit(2)
        }
    }()
    private var replayIndex = 0
    private var replayDeadline: Double = 0
    let sourceFPS: Double = {
        let value = CommandLine.arguments.first { $0.hasPrefix("--fps=") }
            .flatMap { Double($0.dropFirst(6)) } ?? 30
        return value.isFinite && value >= 15 && value <= 120 ? value : 30
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "SwitchViewer 游戏内插帧测试 · \(Int(sourceFPS)) fps"
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentView!.bounds)
        view.wantsLayer = true
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 1920, height: 1080)
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--surface-size=") }) {
            let sizes = argument.dropFirst(15).split(separator: "x").compactMap { Int($0) }
            if sizes.count == 2, sizes.allSatisfy({ (64...8192).contains($0) }) {
                layer.drawableSize = CGSize(width: sizes[0], height: sizes[1])
            }
        }
        view.layer = layer
        window.contentView = view
        queue = layer.device!.makeCommandQueue()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--fullscreen-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in window.toggleFullScreen(nil) }
        }
        if replayIntervals != nil {
            window.title += " · 节奏回放"
            replayDeadline = CACurrentMediaTime()
            scheduleReplay()
        } else {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / sourceFPS, repeats: true) { [self] _ in draw() }
        }
        if CommandLine.arguments.contains("--resize-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [self] in layer.drawableSize = CGSize(width: 1280, height: 720) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [self] in layer.drawableSize = CGSize(width: 1920, height: 1080) }
        }
        if CommandLine.arguments.contains("--resize-storm") {
            // 每 2 秒切换一次 drawable 尺寸，复现游戏在 3024×1898 / 3024×1764 之间来回切。
            // 两个尺寸映射到同一个 1920×1080 代理，所以显示链应该只更新尺寸、不重建会话。
            var toggle = false
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [self] _ in
                toggle.toggle()
                layer.drawableSize = toggle
                    ? CGSize(width: 2560, height: 1440)
                    : CGSize(width: 2048, height: 1152)
            }
        }
        if CommandLine.arguments.contains("--stall-test") {
            // 复现"游戏主线程被占住"：每 3 秒阻塞主线程 220ms。
            // 显示调度挂在 DispatchQueue.main 上，所以这会让提交变晚、帧被丢，
            // 覆盖层停在旧画面上 —— 用来验证埋点能倒带出这段。
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                let deadline = Date().addingTimeInterval(0.220)
                while Date() < deadline { usleep(2_000) }
            }
        }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { NSApp.terminate(nil) }
        }
    }

    private func scheduleReplay() {
        guard let intervals = replayIntervals else { return }
        replayDeadline += intervals[replayIndex % intervals.count]
        replayIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, replayDeadline - CACurrentMediaTime())) { [self] in
            draw()
            // A blocked game thread must not generate a burst of catch-up frames.
            if CACurrentMediaTime() > replayDeadline + intervals[replayIndex % intervals.count] {
                replayDeadline = CACurrentMediaTime()
            }
            scheduleReplay()
        }
    }

    func draw() {
        let offscreen = CommandLine.arguments.contains("--offscreen-producer")
        let drawable: CAMetalDrawable
        if offscreen {
            if CommandLine.arguments.contains("--root-output"), let view = window.contentView {
                layer.bounds = view.bounds
                layer.drawableSize = CGSize(width: view.bounds.width * window.backingScaleFactor,
                                            height: view.bounds.height * window.backingScaleFactor)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: layer.pixelFormat,
                width: Int(layer.drawableSize.width), height: Int(layer.drawableSize.height), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            guard let texture = layer.device?.makeTexture(descriptor: descriptor) else { return }
            drawable = ScratchDrawable(texture: texture, layer: layer)
        } else {
            guard let next = layer.nextDrawable() else { return }
            drawable = next
        }
        guard let buffer = queue.makeCommandBuffer() else { return }
        buffer.label = "FixtureFrame:\(count)"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let marker = CommandLine.arguments.contains("--validate-copy") ? Double(count % 251) / 255 : 0.05
        pass.colorAttachments[0].clearColor = MTLClearColor(red: marker, green: 0.1, blue: 0.2, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        // Moving bright rectangle gives interpolation a spatial motion signal.
        let width = drawable.texture.width
        let x = (count * 12) % max(1, width - 160)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 160, height: 160, mipmapped: false)
        descriptor.storageMode = .shared
        let square = layer.device!.makeTexture(descriptor: descriptor)!
        let pixels = [UInt8](repeating: 230, count: 160 * 160 * 4)
        pixels.withUnsafeBytes { square.replace(region: MTLRegionMake2D(0, 0, 160, 160), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 640) }
        let blit = buffer.makeBlitCommandEncoder()!
        blit.copy(from: square, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: 160, height: 160, depth: 1), to: drawable.texture,
            destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: x, y: 300, z: 0))
        blit.endEncoding()
        count += 1
        if offscreen {
            let requestTime = CACurrentMediaTime()
            typealias Prepare = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer, Double, Double, Double, Double) -> UInt64
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SVGameHookPrepare") else {
                fputs("Offscreen producer requires the injected hook library\n", stderr)
                NSApp.terminate(nil); return
            }
            let prepare = unsafeBitCast(symbol, to: Prepare.self)
            buffer.addCompletedHandler { [self] completed in
                guard completed.status == .completed, let copy = queue.makeCommandBuffer() else { return }
                copy.label = completed.label
                _ = prepare(Unmanaged.passUnretained(copy as AnyObject).toOpaque(),
                    Unmanaged.passUnretained(drawable as AnyObject).toOpaque(),
                    Unmanaged.passUnretained(layer).toOpaque(), requestTime, -1, 0, completed.gpuEndTime)
                copy.commit()
            }
            buffer.commit(); return
        }
        if CommandLine.arguments.contains("--direct-presentation") {
            let variant = count % 3
            let lead = CommandLine.arguments.first { $0.hasPrefix("--native-present-lead-ms=") }
                .flatMap { Double($0.dropFirst(25)) } ?? 0
            if CommandLine.arguments.contains("--direct-before-commit") {
                drawable.present(); buffer.commit(); return
            }
            if CommandLine.arguments.contains("--direct-in-flight") {
                buffer.commit(); drawable.present(at: CACurrentMediaTime() + lead / 1000); return
            }
            buffer.addCompletedHandler { _ in
                if lead > 0 { drawable.present(at: CACurrentMediaTime() + lead / 1000); return }
                if variant == 0 { drawable.present() }
                else if variant == 1 { drawable.present(at: CACurrentMediaTime()) }
                else { drawable.present(afterMinimumDuration: 0) }
            }
        } else if count % 3 == 0 { buffer.present(drawable, atTime: CACurrentMediaTime()) }
        else if count % 3 == 1 { buffer.present(drawable) }
        else { buffer.present(drawable, afterMinimumDuration: 0) }
        buffer.commit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.run()
