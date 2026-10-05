import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation
import SwitchViewerRecording

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var waitingForRecordingTermination = false
    var comparisonRecordingStatus = ""
    var comparisonRecordingDirectory: URL?
    lazy var comparisonRecorder = ComparisonMovieRecorder { [weak self] event in
        DispatchQueue.main.async { self?.receiveComparisonRecordingEvent(event) }
    }

    override init() {
        super.init()
        _ = comparisonRecorder // Initialize on main before capture callbacks can run.
    }

    struct DisplayLatencySample {
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
        let targetToPresentedMilliseconds: Double?
    }

    var window: NSWindow!
    var gameOverlayPanel: GameOverlayPanel?
    var gameOperationMenuItem: NSMenuItem!
    var gameOperationOwner: NSRunningApplication?
    var gameOperationActivationObserver: NSObjectProtocol?
    var gameOperationVisibilityTimer: Timer?
    var pendingGameOperationMode = false
    var rootView: NSView!
    var previewView: PreviewView!
    var devicePopup: NSPopUpButton!
    var formatPopup: NSPopUpButton!
    var volumeSlider: NSSlider!
    var isMuted = false
    var audioVolume: Float = 1
    var isAlwaysOnTop = false
    var isClickThrough = false

    var deviceMenu: NSMenu!
    var formatMenu: NSMenu!
    var statusTextItem: NSMenuItem!
    var statusDetailsItem: NSMenuItem!
    var muteMenuItem: NSMenuItem!
    var floatMenuItem: NSMenuItem!
    var clickThroughMenuItem: NSMenuItem!
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

    // 画面来源：采集卡或屏幕捕获。两者共用同一条插帧/呈现链路。
    var videoSource: VideoSourceKind = .captureCard
    var screenCaptureSource: ScreenCaptureSource?
    var screenCaptureToken = UUID()
    var sourceMenu: NSMenu!
    var hasSelectedSource = false {
        didSet {
            guard hasSelectedSource != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                NSApp.setActivationPolicy(hasSelectedSource ? .regular : .accessory)
                gameInjectionController.synchronizeWorkflow()
            }
        }
    }
    lazy var gameInjectionController: GameInjectionController = {
        let controller = GameInjectionController { [weak self] message in self?.diagnosticLog.append(message) }
        controller.onShowSources = { [weak self] in
            self?.showConfiguration()
        }
        controller.onCreateToolbar = { [weak self] toolbar in
            guard let self else { return }
            toolbar.installConfiguration(ViewerSettingsView(owner: self), owner: self)
        }
        controller.onWillLaunch = { [weak self] in
            if self?.hasSelectedSource == true { self?.stopCapture() }
        }
        controller.onComparisonRecordingSettled = { [weak self] in self?.finishRecordingTerminationIfReady() }
        return controller
    }()
    var autoCropScreenCapture = UserDefaults.standard.object(forKey: "autoCropScreenCapture") as? Bool ?? true
    var uniformProxyFrames = UserDefaults.standard.bool(forKey: "uniformProxyFrames")
    var uniformProxyMenuItem: NSMenuItem!
    var screenTargets: [ScreenCaptureSource.Target] = []
    var selectedScreenTarget: ScreenCaptureSource.Target?
    var screenTargetsLoading = false
    var screenContentAccessConfirmed = false
    var screenTargetsError: String?
    let launchOptions = LaunchOptions.parse(CommandLine.arguments)
    var pendingScreenTargetSpec: String?
    var screenTargetAttempts = 0
    /// 启动失败过的窗口 ID；重试时跳过，避免一直撞同一个临时窗口。
    var failedScreenTargetIDs: Set<UInt32> = []
    /// 需要等首个帧到达、尺寸确定后再应用的插帧方式。
    var pendingInterpolationMode: FrameInterpolationMode?

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
    var signatureDuplicateSourceCount = 0
    var signatureCompareCount = 0
    var signatureCompareTotalMilliseconds = 0.0
    var signatureCompareMaxMilliseconds = 0.0
    var lastAcceptedSourceSignature: DisplayFrameSignature?
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
    var frameInterpolationMode = FrameInterpolationMode.appleProxy
    var presentationPacingMode = PresentationPacingMode.cadenceLimited
    var presentationPacingMenuItems: [NSMenuItem] = []
    var frameInterpolationEngine: FrameInterpolationEngine?
    var detectedGameFPS: Double?
    let contentFrameRateMonitor = ContentFrameRateMonitor()
    var observedContentFPS: Double?
    var deadlineCadenceActive = false
    var consecutiveNonDeadlineCadenceFrames = 0
    var consecutiveDeadlineCadenceFrames = 0
    let deadlineCadenceLossGraceFrames = 60
    let deadlineCadenceRecoveryFrames = 8
    var nextSourceFrameID: UInt64 = 0
    lazy var presentationScheduler = PresentationScheduler(
        onFrame: { [weak self] frame, epoch in
            guard let self else { return }
            self.enqueuePresentationFrames([frame], epoch: epoch, requireInterpolation: true)
        },
        onReport: { [weak self] report in self?.diagnosticLog.append(report) })
    let screenContentDetector = ContentFrameCadenceDetector()
    lazy var screenPresentationScheduler = PresentationScheduler(contentTimed: true,
        onFrame: { [weak self] frame, epoch in
            guard let self else { return }
            self.enqueuePresentationFrames([frame], epoch: epoch, requireInterpolation: true)
        },
        onReport: { [weak self] report in self?.diagnosticLog.append(report) })
    var frameInterpolationEnabled = false
    var screenOutputSuspended = false
    var frameInterpolationUnavailable = false
    var frameInterpolationEpoch = 0
    var interpolatedFrameCount = 0
    var interpolationRepeatedFrameSkipCount = 0
    var interpolationFailureCount = 0
    var lastInterpolationError: String?
    let diagnosticLog = RollingDiagnosticsLog()
    let displayTimingQueue = DispatchQueue(label: "switchviewer.display-timing")
    var displayTimingSamples: [DisplayLatencySample] = []
    var shownFrameTimes: [CFTimeInterval] = []
    // Accessed only on displayTimingQueue, before interpolation or display drops.
    var capturedSourceCount = 0
    var shownMidpointCount = 0
    var lastDisplayTimingReportUptime = ProcessInfo.processInfo.systemUptime
    struct CaptureCallbackTimingSample {
        let ptsToCallbackMilliseconds: Double?
        let callbackWorkMilliseconds: Double
        let signatureSamplingMilliseconds: Double?
    }
    let captureCallbackTimingQueue = DispatchQueue(label: "switchviewer.capture-callback-timing")
    var captureCallbackTimingSamples: [CaptureCallbackTimingSample] = []
    var lastCaptureCallbackTimingReportUptime = ProcessInfo.processInfo.systemUptime
    let captureDisplayAwakeAssertion = CaptureDisplayAwakeAssertion()

    // Caller must hold frameLock.
    func clearDeadlineCadenceQualificationLocked() {
        deadlineCadenceActive = false
        consecutiveNonDeadlineCadenceFrames = 0
        consecutiveDeadlineCadenceFrames = 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnosticLog.append("应用启动; macOS=\(ProcessInfo.processInfo.operatingSystemVersionString); 日志目录=\(diagnosticLog.directoryURL.path); 参数=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
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
        diagnosticLog.append("低延迟呈现队列; maximumDrawableCount=\(maximumPresentationInFlightFrames); inFlightLimit=\(maximumPresentationInFlightFrames); presentationPacing=\(presentationPacingMode.label); captureCallbackQueueQoS=userInteractive; sourceDedupe=sampledDisplaySignature(Y=256x144,UV=128x72)")
        NSApp.setActivationPolicy(.accessory)
        gameInjectionController.show()
        window.orderOut(nil)
        diagnosticLog.append("屏幕捕获权限; granted=\(ScreenCaptureSource.hasPermission); source=\(videoSource == .captureCard ? "captureCard" : "screen")")
        applyLaunchOptions()
        if pendingScreenTargetSpec != nil { reloadScreenTargets(userInitiated: false) }
        NotificationCenter.default.addObserver(self, selector: #selector(deviceDisconnected(_:)),
                                               name: .AVCaptureDeviceWasDisconnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceConnected(_:)),
                                               name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted, object: session)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tickFps()
        }
        Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.logPeriodicDiagnostics()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard comparisonRecorder.isBusy || gameInjectionController.comparisonRecordingBusy else { return .terminateNow }
        waitingForRecordingTermination = true
        if comparisonRecorder.isBusy { comparisonRecorder.stop() }
        if gameInjectionController.isComparisonRecording { gameInjectionController.toggleComparisonRecording() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        gameInjectionController.shutdown()
        if let observer = gameOperationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        stopScreenCapture()
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
        let presentationPacing = videoSource == .screen && interpolationEnabled
            ? "按屏幕内容时间戳定时" : presentationPacingMode.label
        let interpolationFailures = interpolationFailureCount
        let interpolationError = lastInterpolationError ?? "无"
        let inputQueueDrops = inputQueueDropCount
        let presentationLimitDrops = presentationLimitDropCount
        let rendererFailures = rendererFailureCount
        let signatureDuplicateSources = signatureDuplicateSourceCount
        let signatureComparisons = signatureCompareCount
        let signatureCompareTotal = signatureCompareTotalMilliseconds
        let signatureCompareMax = signatureCompareMaxMilliseconds
        frameLock.unlock()

        let selectedIndex = formatPopup.indexOfSelectedItem
        let selected = formatOptions.indices.contains(selectedIndex) ? formatOptions[selectedIndex].label : "无"
        let actual = currentVideoDevice.map(actualFormatLine) ?? "无设备"
        let signatureCompareAverage = signatureComparisons > 0
            ? signatureCompareTotal / Double(signatureComparisons) : 0
        let sourceCounters = screenCaptureSource?.counters ?? (delivered: 0, replayed: 0, empty: 0)
        let sourceLabel = videoSource == .captureCard ? "captureCard" : "screen"
        diagnosticLog.append("定时状态; source=\(sourceLabel); screenDelivered=\(sourceCounters.delivered); screenReplayed=\(sourceCounters.replayed); screenEmptyCallback=\(sourceCounters.empty); session=\(session.isRunning ? "运行中" : "停止"); preset=\(session.sessionPreset.rawValue); device=\(currentVideoDevice?.localizedName ?? "无"); audio=\(currentAudioDevice?.localizedName ?? "无"); requested=\(selected); active=\(actual); buffer=\(width)x\(height) \(pixelFormat); submittedFPS=\(String(format: "%.1f", fps)); frames=\(frames); dropped=\(dropped); inputQueueDrops=\(inputQueueDrops); presentationLimitDrops=\(presentationLimitDrops); rendererFailures=\(rendererFailures); signatureDuplicateSourcesSuppressed=\(signatureDuplicateSources); signatureComparisons=\(signatureComparisons); signatureCompareAvgMaxMs=\(String(format: "%.3f/%.3f", signatureCompareAverage, signatureCompareMax)); frameInterpolation=\(interpolationEnabled ? "开" : "关"); interpolationMode=\(frameInterpolationMode.label); presentationPacing=\(presentationPacing); interpolatedFrames=\(interpolatedFrames); repeatedFrameSkips=\(repeatedFrameSkips); interpolationFailures=\(interpolationFailures); interpolationError=\(interpolationError); lastFrame=\(lastFrameAge); renderError=\(renderError); metal=\(metalInitError ?? "OK"); fallback=\(fallbackLayer == nil ? "否" : "是"); color=\(renderer?.colorMode.label ?? "无")")
    }

    // Metal 不可用时切回系统预览层，保证不断片
    func enableFallback(_ reason: String) {
        DispatchQueue.main.async {
            guard self.fallbackLayer == nil else { return }
            self.frameLock.lock()
            self.frameInterpolationEpoch += 1
            let epoch = self.frameInterpolationEpoch
            self.frameInterpolationEnabled = false
            self.clearDeadlineCadenceQualificationLocked()
            self.frameInterpolationMenuItem?.state = .off
            let interpolationEngine = self.frameInterpolationEngine
            self.frameLock.unlock()
            self.presentationScheduler.reset(epoch: epoch)
            self.resetScreenTiming(epoch: epoch)
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

    // MARK: 窗口

    func windowDidChangeBackingProperties(_ notification: Notification) {
        // 换显示器 / 缩放变化时跟上 DPI
        let s = previewView.window?.backingScaleFactor ?? 2.0
        previewView.metalLayer.contentsScale = s
        previewView.fallbackLayer?.contentsScale = s
        previewView.needsLayout = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard pendingGameOperationMode else { return }
        pendingGameOperationMode = false
        enterGameOperationMode()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if hasSelectedSource { showPreview() }
        else { gameInjectionController.show() }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Opening the source controls provides an escape without intercepting game keys.
        if gameOverlayPanel != nil { leaveGameOperationMode() }
    }

    @objc func toggleGameOperationMode(_ sender: Any?) {
        if gameOverlayPanel != nil { leaveGameOperationMode(); return }
        guard videoSource == .screen, selectedScreenTarget?.kind == .window,
              selectedScreenTarget?.processID != nil else {
            setStatus("请先选择游戏窗口，再开启游戏操作模式", base: false)
            return
        }
        if window.styleMask.contains(.fullScreen) {
            pendingGameOperationMode = true
            window.toggleFullScreen(nil)
        } else { enterGameOperationMode() }
    }

    func enterGameOperationMode() {
        guard gameOverlayPanel == nil, videoSource == .screen,
              let pid = selectedScreenTarget?.processID,
              pid != ProcessInfo.processInfo.processIdentifier,
              let owner = NSRunningApplication(processIdentifier: pid), !owner.isTerminated,
              let screen = window.screen ?? NSScreen.main else {
            setStatus("游戏窗口已不可用，请重新选择画面来源", base: false)
            return
        }
        let panel = GameOverlayPanel(screen: screen)
        gameOverlayPanel = panel
        gameOperationOwner = owner
        window.orderOut(nil)
        window.contentView = nil
        panel.contentView = rootView
        rootView.frame = NSRect(origin: .zero, size: screen.frame.size)
        panel.delegate = self
        previewView.needsLayout = true
        previewView.layoutSubtreeIfNeeded()
        gameOperationMenuItem.state = .on
        if !owner.activate(options: [.activateIgnoringOtherApps, .activateAllWindows]) {
            leaveGameOperationMode()
            setStatus("无法将焦点交给游戏，请确认游戏仍在运行", base: false)
            return
        }
        updateGameOverlayVisibility()
        gameOperationVisibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateGameOverlayVisibility()
        }
        gameOperationActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.updateGameOverlayVisibility()
        }
        diagnosticLog.append("游戏操作模式; enabled=true; gamePID=\(pid); overlayWindow=\(panel.windowNumber); overlayCanBecomeKey=\(panel.canBecomeKey)")
    }

    func updateGameOverlayVisibility() {
        guard let panel = gameOverlayPanel, let owner = gameOperationOwner else { return }
        frameLock.lock()
        let hasFrame = lastWidth > 0 && lastHeight > 0
        screenOutputSuspended = !owner.isActive
        frameLock.unlock()
        // Leave the actual game visible while waiting for the first capture frame.
        let shouldShow = hasFrame && owner.isActive
        if shouldShow && !panel.isVisible { panel.orderFrontRegardless() }
        else if !shouldShow && panel.isVisible { panel.orderOut(nil) }
    }

    func leaveGameOperationMode() {
        pendingGameOperationMode = false
        guard let panel = gameOverlayPanel else { return }
        gameOperationVisibilityTimer?.invalidate()
        gameOperationVisibilityTimer = nil
        if let observer = gameOperationActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            gameOperationActivationObserver = nil
        }
        panel.orderOut(nil)
        panel.contentView = nil
        window.contentView = rootView
        rootView.frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        panel.close()
        gameOverlayPanel = nil
        gameOperationOwner = nil
        frameLock.lock()
        screenOutputSuspended = false
        frameLock.unlock()
        gameOperationMenuItem.state = .off
        previewView.needsLayout = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        diagnosticLog.append("游戏操作模式; enabled=false")
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
        // Match LSUIElement when running the executable outside the app bundle.
        NSApp.setActivationPolicy(.accessory)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow else { return event }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "i": self.toggleFrameInterpolation(event); return nil
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
