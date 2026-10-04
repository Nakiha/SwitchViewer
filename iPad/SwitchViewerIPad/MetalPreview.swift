import SwiftUI
import MetalKit
import CoreImage

struct MetalPreview: UIViewRepresentable {
    let controller: CaptureController

    func makeCoordinator() -> Renderer { Renderer(controller: controller) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = true
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    static func dismantleUIView(_ view: MTKView, coordinator: Renderer) { coordinator.stop() }

    final class Renderer: NSObject, MTKViewDelegate {
        private let controller: CaptureController
        private weak var view: MTKView?
        private var link: CADisplayLink?
        private var context: CIContext?
        private var queue: MTLCommandQueue?
        private var current: PreviewFrame?
        private let inFlight = DispatchSemaphore(value: 2)
        private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        private var redraw = false
        private var lastGeneration: UInt64 = 0

        init(controller: CaptureController) { self.controller = controller }

        func attach(_ view: MTKView) {
            self.view = view
            if let device = view.device {
                context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
                queue = device.makeCommandQueue()
            }
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() { link?.invalidate(); link = nil }

        @objc private func tick(_ link: CADisplayLink) {
            let generation = controller.pipeline.frames.generation
            if generation != lastGeneration {
                lastGeneration = generation
                current = nil
                redraw = true
            }
            if let entry = controller.pipeline.frames.take(at: link.targetTimestamp) {
                current = entry.frame
                redraw = true
            }
            if redraw { view?.draw() }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { redraw = true }

        func draw(in view: MTKView) {
            guard inFlight.wait(timeout: .now()) == .success else { return }
            guard let context, let command = queue?.makeCommandBuffer(),
                  let drawable = view.currentDrawable else { inFlight.signal(); return }
            let bounds = CGRect(origin: .zero, size: view.drawableSize)
            var image = CIImage(color: .black).cropped(to: bounds)
            let frame = current
            if let frame {
                let input = CIImage(cvPixelBuffer: frame.buffer)
                let width = min(bounds.width, bounds.height * frame.sourceAspect)
                let height = width / frame.sourceAspect
                let transform = CGAffineTransform(scaleX: width / input.extent.width,
                                                  y: height / input.extent.height)
                    .concatenating(CGAffineTransform(translationX: (bounds.width - width) / 2,
                                                    y: (bounds.height - height) / 2))
                image = input.transformed(by: transform).composited(over: image)
            }
            context.render(image, to: drawable.texture, commandBuffer: command,
                           bounds: bounds, colorSpace: colorSpace)
            if let frame {
                let controller = controller
                #if targetEnvironment(simulator)
                command.addCompletedHandler { _ in
                    controller.recordPresentation(at: CACurrentMediaTime(), receivedAt: frame.receivedAt,
                                                  interpolated: frame.interpolated)
                }
                #else
                drawable.addPresentedHandler { presented in
                    let time = presented.presentedTime
                    guard time > 0 else { return }
                    controller.recordPresentation(at: time, receivedAt: frame.receivedAt,
                                                  interpolated: frame.interpolated)
                }
                #endif
            }
            let semaphore = inFlight
            command.addCompletedHandler { _ in
                withExtendedLifetime(frame) {}
                semaphore.signal()
            }
            command.present(drawable)
            command.commit()
            redraw = false
        }
    }
}
