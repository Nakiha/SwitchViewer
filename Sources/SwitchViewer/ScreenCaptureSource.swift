import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

/// Captures a display or a single window with ScreenCaptureKit and delivers NV12
/// frames into SwitchViewer's existing frame path.
///
/// ScreenCaptureKit already stamps sample buffers on the host clock, so unlike the
/// capture card there is no capture-session clock to convert. Capture is requested
/// at the source's native pixel size: SwitchViewer downsamples to an Apple-supported
/// proxy itself, exactly like the 4K capture-card path.
///
/// `minimumFrameInterval` is set to 60 Hz so the callback grid matches the capture
/// card. Window capture reports unchanged ticks as `SCFrameStatusIdle` with no pixel
/// buffer; those are replayed with the previous buffer so the existing cadence
/// detector still sees a fixed-rate stream containing duplicate frames.
final class ScreenCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Target: Equatable {
        enum Kind: Equatable {
            case display
            case window
        }

        let kind: Kind
        /// `SCDisplay.displayID` for displays, `SCWindow.windowID` for windows.
        let id: UInt32
        /// Owning application name; empty for displays.
        let applicationName: String
        /// Window title; the display's name for displays.
        let title: String
        /// Size in points for windows, in pixels for displays.
        let width: Int
        let height: Int
        var processID: pid_t? = nil

        var menuTitle: String {
            applicationName.isEmpty ? "\(title) · \(width)×\(height)"
                                    : "\(applicationName) — \(title) · \(width)×\(height)"
        }
    }

    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let presentationTimeStamp: CMTime
        /// Host-clock seconds, same domain as `CMClockGetHostTimeClock()`.
        let callbackHostTime: CFTimeInterval
        /// True when ScreenCaptureKit reported no content change and the previous
        /// buffer was replayed to keep the grid at a fixed rate.
        let isReplayed: Bool
    }

    enum SourceError: Error, LocalizedError, CustomStringConvertible {
        case noPermission
        case shareableContentUnavailable(String)
        case targetMissing
        case invalidSize(Int, Int)
        case stream(String)

        var description: String {
            switch self {
            case .noPermission:
                return "没有“屏幕录制”权限"
            case .shareableContentUnavailable(let message):
                return "无法读取可共享内容：\(message)"
            case .targetMissing:
                return "目标窗口或显示器已不存在"
            case .invalidSize(let width, let height):
                return "屏幕捕获尺寸无效：\(width)×\(height)"
            case .stream(let message):
                return "屏幕捕获失败：\(message)"
            }
        }

        /// `localizedDescription` 走的是 LocalizedError，不实现它日志里只会出现错误序号。
        var errorDescription: String? { description }
    }

    /// 60 Hz keeps the callback grid aligned with the capture card, which the
    /// cadence detector and presentation pacing both assume.
    static let targetFrameInterval = CMTime(value: 1, timescale: 60)
    static let pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    private let onFrame: (Frame) -> Void
    private let onError: (String) -> Void
    private let autoCrop: Bool
    private let onCrop: (String) -> Void
    private let cropper = ScreenCaptureCropper()
    private var displayTopFraction: Double?
    private var windowScale = 1.0
    private var lastCropTop: Int?
    private let outputQueue = DispatchQueue(label: "switchviewer.screen-capture",
                                            qos: .userInteractive)
    private let stateLock = NSLock()
    private var stream: SCStream?
    /// Only touched on `outputQueue`.
    private var lastPixelBuffer: CVPixelBuffer?
    private(set) var capturedSize = (width: 0, height: 0)
    private var deliveredFrames = 0
    private var replayedFrames = 0
    private var emptyCallbacks = 0
    private var targetMonitor: Timer?
    private var targetQueryInFlight = false
    private var missingTargetChecks = 0

    /// 诊断用：SCStream 实际投递了多少个回调、其中多少是重放的 idle tick。
    var counters: (delivered: Int, replayed: Int, empty: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (deliveredFrames, replayedFrames, emptyCallbacks)
    }

    init(onFrame: @escaping (Frame) -> Void,
         onError: @escaping (String) -> Void,
         autoCrop: Bool = true,
         onCrop: @escaping (String) -> Void = { _ in }) {
        self.onFrame = onFrame
        self.onError = onError
        self.autoCrop = autoCrop
        self.onCrop = onCrop
        super.init()
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Lists capturable displays and normal windows, skipping SwitchViewer's own
    /// windows so the app never captures its own preview (which would feed back).
    ///
    /// `onScreenWindowsOnly` is false on purpose: a game running fullscreen lives on
    /// its own Space and would otherwise disappear from the list as soon as the user
    /// switches away from it.
    static func loadTargets(excludingWindowNumbers: Set<CGWindowID>,
                            completion: @escaping ([Target], Error?) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
            guard let content else {
                completion([], error ?? SourceError.shareableContentUnavailable("系统没有返回来源列表"))
                return
            }
            var targets: [Target] = content.displays.map { display in
                Target(kind: .display, id: display.displayID,
                       applicationName: "",
                       title: "显示器 \(display.displayID)",
                       width: display.width, height: display.height)
            }
            for window in content.windows {
                guard window.windowLayer == 0,
                      window.frame.width >= 160, window.frame.height >= 120,
                      !excludingWindowNumbers.contains(window.windowID) else { continue }
                let application = window.owningApplication?.applicationName ?? "未知应用"
                let name = (window.title?.isEmpty == false) ? window.title! : "(无标题)"
                targets.append(Target(kind: .window, id: window.windowID,
                                      applicationName: application,
                                      title: name,
                                      width: Int(window.frame.width),
                                      height: Int(window.frame.height),
                                      processID: window.owningApplication?.processID))
            }
            completion(targets, nil)
        }
    }

    func start(target: Target, excludingWindowNumbers: Set<CGWindowID>,
               completion: @escaping (Error?) -> Void) {
        // NSScreen must be inspected on the main thread, before the asynchronous query.
        let readDisplayInset = {
            guard target.kind == .display,
                  let screen = NSScreen.screens.first(where: {
                      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == target.id
                  }), screen.frame.height > 0 else { return }
            let top = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
            self.displayTopFraction = Double(top / screen.frame.height)
        }
        if Thread.isMainThread { readDisplayInset() }
        else { DispatchQueue.main.sync(execute: readDisplayInset) }
        // 必须与 loadTargets 用同一组过滤条件，否则全屏游戏（在独立 Space 里、
        // 不属于 on-screen 窗口）会在列举时出现、启动时又找不到。
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard let content else {
                completion(SourceError.shareableContentUnavailable(error?.localizedDescription ?? "未知错误"))
                return
            }

            let filter: SCContentFilter
            switch target.kind {
            case .display:
                guard let display = content.displays.first(where: { $0.displayID == target.id }) else {
                    completion(SourceError.targetMissing)
                    return
                }
                let excluded = content.windows.filter { excludingWindowNumbers.contains($0.windowID) }
                filter = SCContentFilter(display: display, excludingWindows: excluded)
            case .window:
                guard let window = content.windows.first(where: { $0.windowID == target.id }) else {
                    completion(SourceError.targetMissing)
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            }

            let configuration = SCStreamConfiguration()
            if #available(macOS 14.0, *) {
                self.windowScale = Double(filter.pointPixelScale)
            }
            let size = Self.captureSize(filter: filter, target: target)
            guard size.width > 0, size.height > 0 else {
                completion(SourceError.invalidSize(size.width, size.height))
                return
            }
            configuration.width = size.width
            configuration.height = size.height
            configuration.pixelFormat = Self.pixelFormat
            // Match the RGB values produced by our YUV shader to the display layer.
            // On wide-gamut displays, an unspecified capture color space can deliver
            // display-gamut values even while the buffer carries an sRGB attachment.
            configuration.colorSpaceName = CGColorSpace.sRGB
            // SwitchViewer 的插帧链路会同时持有若干帧（节奏检测保留 3 帧、待处理队列、
            // 正在插值的 2 帧），队列深度必须大于这个数，否则 ScreenCaptureKit 的缓冲池
            // 会被耗尽，表现为"投递几帧后彻底静默且不报错"。
            configuration.queueDepth = 12
            configuration.minimumFrameInterval = Self.targetFrameInterval
            configuration.scalesToFit = false
            configuration.showsCursor = false
            configuration.capturesAudio = false
            self.capturedSize = size

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
            } catch {
                completion(SourceError.stream(error.localizedDescription))
                return
            }
            self.stateLock.lock()
            self.stream = stream
            self.stateLock.unlock()
            stream.startCapture { [self, stream] error in
                if error == nil {
                    DispatchQueue.main.async { [weak self, weak stream] in
                        guard let self, let stream else { return }
                        self.stateLock.lock()
                        let active = self.stream === stream
                        self.stateLock.unlock()
                        if active { self.monitorTarget(target, stream: stream) }
                    }
                }
                completion(error.map { SourceError.stream($0.localizedDescription) })
            }
        }
    }

    private static func captureSize(filter: SCContentFilter, target: Target) -> (width: Int, height: Int) {
        var width = target.width
        var height = target.height
        if #available(macOS 14.0, *) {
            let scale = Double(filter.pointPixelScale)
            let rect = filter.contentRect
            if scale > 0, rect.width > 1, rect.height > 1 {
                width = Int((rect.width * CGFloat(scale)).rounded())
                height = Int((rect.height * CGFloat(scale)).rounded())
            }
        }
        // NV12 requires even dimensions.
        return (width - (width % 2), height - (height % 2))
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.targetMonitor?.invalidate()
            self?.targetMonitor = nil
        }
        stateLock.lock()
        let current = stream
        stream = nil
        stateLock.unlock()
        outputQueue.async { self.lastPixelBuffer = nil }
        current?.stopCapture { _ in }
    }

    /// A closed window can leave SCStream silently idle without a delegate error.
    /// Check existence, never frame activity: static/minimized windows are valid.
    private func monitorTarget(_ target: Target, stream: SCStream) {
        targetMonitor?.invalidate()
        targetMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak stream] _ in
            guard let self, let stream, !self.targetQueryInFlight else { return }
            self.stateLock.lock()
            let active = self.stream === stream
            self.stateLock.unlock()
            guard active else { return }
            self.targetQueryInFlight = true
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self, weak stream] content, _ in
                DispatchQueue.main.async {
                    guard let self, let stream else { return }
                    self.targetQueryInFlight = false
                    self.stateLock.lock()
                    let active = self.stream === stream
                    self.stateLock.unlock()
                    guard active, let content else { return }
                    let ownerExists = target.processID.map { pid in
                        kill(pid, 0) == 0 || errno == EPERM
                    } ?? true
                    let exists = ownerExists && (target.kind == .window
                        ? content.windows.contains { $0.windowID == target.id }
                        : content.displays.contains { $0.displayID == target.id })
                    self.missingTargetChecks = exists ? 0 : self.missingTargetChecks + 1
                    guard self.missingTargetChecks >= 2 else { return }
                    self.targetMonitor?.invalidate()
                    self.targetMonitor = nil
                    self.onError(target.kind == .window
                        ? "捕获窗口已关闭，请重新选择画面来源"
                        : "捕获显示器已断开，请重新选择画面来源")
                }
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        stateLock.lock()
        let active = self.stream === stream
        stateLock.unlock()
        guard active else { return }
        guard type == .screen else { return }
        let callbackHostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var status: SCFrameStatus?
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                     createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let first = attachments.first,
           let raw = first[.status] as? NSNumber {
            status = SCFrameStatus(rawValue: raw.intValue)
        }

        if (status == nil || status == .complete),
           let captured = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let pixelBuffer: CVPixelBuffer
            if autoCrop {
                guard let cropped = cropper.process(captured,
                                                     displayTopFraction: displayTopFraction,
                                                     windowScale: windowScale) else {
                    onError("自动裁切缓冲分配失败；请关闭自动裁切后重试")
                    return
                }
                pixelBuffer = cropped.buffer
                if lastCropTop != cropped.top {
                    lastCropTop = cropped.top
                    onCrop("自动裁切; top=\(cropped.top)px; input=\(CVPixelBufferGetWidth(captured))x\(CVPixelBufferGetHeight(captured)); output=\(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
                }
            } else {
                pixelBuffer = captured
            }
            lastPixelBuffer = pixelBuffer
            stateLock.lock(); deliveredFrames += 1; stateLock.unlock()
            onFrame(Frame(pixelBuffer: pixelBuffer,
                          presentationTimeStamp: presentationTimeStamp,
                          callbackHostTime: callbackHostTime,
                          isReplayed: false))
            return
        }

        // No pixels: either the content did not change or the display is asleep.
        // Replay the last buffer on unchanged ticks so the downstream cadence
        // detector still sees the fixed-rate grid it expects.
        guard status == .idle, let previous = lastPixelBuffer else {
            stateLock.lock(); emptyCallbacks += 1; stateLock.unlock()
            return
        }
        stateLock.lock(); replayedFrames += 1; stateLock.unlock()
        onFrame(Frame(pixelBuffer: previous,
                      presentationTimeStamp: presentationTimeStamp,
                      callbackHostTime: callbackHostTime,
                      isReplayed: true))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let active = self.stream === stream
        stateLock.unlock()
        guard active else { return }
        onError("屏幕捕获已停止：\(error.localizedDescription)")
    }
}
