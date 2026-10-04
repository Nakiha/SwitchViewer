import Cocoa
import AVFoundation
import CoreImage
import CoreMedia
import IOKit.pwr_mgt
import Metal
import VideoToolbox
import simd
import SwitchViewerInterpolation

extension AppDelegate {
    func hostTime(forCaptureTimestamp timestamp: CMTime) -> CFTimeInterval? {
        guard CMTimeGetSeconds(timestamp).isFinite else { return nil }
        switch videoSource {
        case .captureCard:
            guard let captureClock = session.synchronizationClock else { return nil }
            let hostTimestamp = CMSyncConvertTime(timestamp,
                                                  from: captureClock,
                                                  to: CMClockGetHostTimeClock())
            let seconds = CMTimeGetSeconds(hostTimestamp)
            return seconds.isFinite ? seconds : nil
        case .screen:
            // ScreenCaptureKit already stamps sample buffers on the host clock.
            let seconds = CMTimeGetSeconds(timestamp)
            return seconds.isFinite ? seconds : nil
        }
    }

    // MARK: 画面来源切换

    /// Bumps the frame epoch and clears per-session counters. Shared by the
    /// capture-card session and the screen-capture source so frames from the
    /// previous source can never be presented after a switch.
    @discardableResult
    func beginNewSourceGeneration(reason: String) -> Int {
        frameLock.lock()
        frameInterpolationEpoch += 1
        let epoch = frameInterpolationEpoch
        detectedGameFPS = nil
        observedContentFPS = nil
        clearDeadlineCadenceQualificationLocked()
        interpolatedFrameCount = 0
        interpolationRepeatedFrameSkipCount = 0
        interpolationFailureCount = 0
        lastInterpolationError = nil
        frameCount = 0
        droppedCount = 0
        inputQueueDropCount = 0
        presentationLimitDropCount = 0
        rendererFailureCount = 0
        signatureDuplicateSourceCount = 0
        signatureCompareCount = 0
        signatureCompareTotalMilliseconds = 0
        signatureCompareMaxMilliseconds = 0
        lastAcceptedSourceSignature = nil
        consecFails = 0
        didLogRenderFailure = false
        firstRenderError = nil
        lastRenderError = nil
        lastSetDesc = nil
        setVerifyDesc = nil
        lastPixelBuffer = nil
        lastPixelFormat = 0
        lastWidth = 0
        lastHeight = 0
        lastFrameDate = nil
        tickCount = 0
        tickDate = Date()
        measuredFps = 0
        sessionGeneration += 1
        let generation = sessionGeneration
        let interpolationEngine = frameInterpolationEngine
        frameLock.unlock()
        presentationScheduler.reset(epoch: epoch)
        resetScreenTiming(epoch: epoch)
        interpolationEngine?.reset()
        diagnosticLog.append("开始新的画面来源代次; reason=\(reason); epoch=\(epoch); generation=\(generation)")
        return generation
    }

    func resetScreenTiming(epoch: Int) {
        frameLock.lock()
        screenContentDetector.reset()
        frameLock.unlock()
        screenPresentationScheduler.reset(epoch: epoch)
    }

    func handleScreenCaptureFrame(_ frame: ScreenCaptureSource.Frame) {
        guard videoSource == .screen else { return }
        frameLock.lock()
        let skipIdle = frameInterpolationEnabled && frame.isReplayed
        let suspended = screenOutputSuspended
        if skipIdle { interpolationRepeatedFrameSkipCount += 1 }
        frameLock.unlock()
        guard !skipIdle && !suspended else { return }
        let callbackWorkStart = ProcessInfo.processInfo.systemUptime
        let presentationTimestampHostTime = hostTime(forCaptureTimestamp: frame.presentationTimeStamp)
        var ptsToCallbackMilliseconds: Double?
        if let presentationTimestampHostTime,
           frame.callbackHostTime >= presentationTimestampHostTime {
            ptsToCallbackMilliseconds = (frame.callbackHostTime - presentationTimestampHostTime) * 1_000
        }
        let signatureSamplingMilliseconds = handleVideoFrame(
            pixelBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            captureCallbackHostTime: frame.callbackHostTime,
            presentationTimestampHostTime: presentationTimestampHostTime)
        let callbackWorkMilliseconds = (ProcessInfo.processInfo.systemUptime - callbackWorkStart) * 1_000
        recordCaptureCallbackTiming(ptsToCallbackMilliseconds: ptsToCallbackMilliseconds,
                                    callbackWorkMilliseconds: callbackWorkMilliseconds,
                                    signatureSamplingMilliseconds: signatureSamplingMilliseconds)
    }

    func ownWindowNumbers() -> Set<CGWindowID> {
        // A window that has not been shown can still have a negative number.
        Set(NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) })
    }

    /// `display:first` / `display:<id>` / `app:<名称子串>` / `title:<标题子串>`
    func resolveScreenTarget(_ spec: String) -> ScreenCaptureSource.Target? {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? ""
        let value = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "display":
            if value.isEmpty || value == "first" {
                return screenTargets.first { $0.kind == .display }
            }
            guard let id = UInt32(value) else { return nil }
            return screenTargets.first { $0.kind == .display && $0.id == id }
        case "app", "title":
            guard !value.isEmpty else { return nil }
            let windows = screenTargets.filter {
                $0.kind == .window && !failedScreenTargetIDs.contains($0.id)
            }
            let matches = kind == "app"
                ? windows.filter { $0.applicationName.localizedCaseInsensitiveContains(value) }
                : windows.filter { $0.title.localizedCaseInsensitiveContains(value) }
            // 同名窗口可能有多个，取面积最大的那个（通常就是游戏主窗口）。
            return matches.max { $0.width * $0.height < $1.width * $1.height }
        default:
            return nil
        }
    }

    func applyLaunchOptions() {
        guard launchOptions.screenTarget != nil
            || launchOptions.requestScreenPermission
            || launchOptions.enableInterpolation
            || launchOptions.interpolationMode != nil
            || launchOptions.clickThrough else { return }
        diagnosticLog.append("启动参数; screenTarget=\(launchOptions.screenTarget ?? "-")"
                             + "; requestPermission=\(launchOptions.requestScreenPermission)"
                             + "; interpolationMode=\(launchOptions.interpolationMode?.label ?? "-")"
                             + "; enableInterpolation=\(launchOptions.enableInterpolation)"
                             + "; clickThrough=\(launchOptions.clickThrough)")
        if launchOptions.clickThrough, !isClickThrough { toggleClickThrough(self) }
        if launchOptions.requestScreenPermission, !ScreenCaptureSource.hasPermission {
            let granted = ScreenCaptureSource.requestPermission()
            diagnosticLog.append("启动参数申请屏幕录制权限; granted=\(granted)")
        }
        if launchOptions.enableInterpolation || launchOptions.interpolationMode != nil {
            pendingInterpolationMode = launchOptions.interpolationMode ?? .appleProxy
        }
        pendingScreenTargetSpec = launchOptions.screenTarget
    }

    /// 启动参数指定的插帧方式要等首个帧到达、缓冲尺寸确定后才能通过可用性检查。
    func applyPendingInterpolationIfNeeded() {
        if let requested = pendingInterpolationMode {
            pendingInterpolationMode = nil
            applyFrameInterpolationMode(requested)
        }
        guard launchOptions.enableInterpolation else { return }
        frameLock.lock()
        let enabled = frameInterpolationEnabled
        frameLock.unlock()
        if !enabled { toggleFrameInterpolation(self) }
    }

    func startScreenCapture(target: ScreenCaptureSource.Target) {
        leaveGameOperationMode()
        markSourceSelected()
        beginNewSourceGeneration(reason: "屏幕捕获 \(target.menuTitle)")
        stopScreenCapture()
        let captureToken = UUID()
        screenCaptureToken = captureToken
        videoSource = .screen
        selectedScreenTarget = target
        refreshSourceMenu()
        diagnosticLog.append("切换画面来源; source=screen; target=\(target.menuTitle); points=\(target.width)x\(target.height)")

        // 采集卡必须让出链路：两条来源共用同一个帧入口。
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setCaptureDisplayAwake(false, reason: "切换到屏幕捕获")
            if self.session.isRunning { self.session.stopRunning() }
            if let locked = self.lockedFormatDevice {
                locked.unlockForConfiguration()
                self.lockedFormatDevice = nil
                self.diagnosticLog.append("屏幕捕获接管，已释放采集卡格式锁; device=\(locked.localizedName)")
            }
        }

        let source = ScreenCaptureSource(
            onFrame: { [weak self] frame in self?.handleScreenCaptureFrame(frame) },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self, self.screenCaptureToken == captureToken else { return }
                    self.returnToSourceSelection(message: message)
                }
            },
            autoCrop: autoCropScreenCapture,
            onCrop: { [weak self] message in self?.diagnosticLog.append(message) })
        screenCaptureSource = source
        source.start(target: target, excludingWindowNumbers: ownWindowNumbers()) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.screenCaptureToken == captureToken,
                      self.videoSource == .screen, self.selectedScreenTarget == target else { return }
                guard let error else {
                    let size = source.capturedSize
                    self.screenTargetAttempts = 0
                    self.pendingScreenTargetSpec = nil
                    self.setStatus("屏幕捕获 · \(target.menuTitle) · \(size.width)×\(size.height)")
                    self.window.title = "SwitchViewer - 屏幕捕获"
                    self.setCaptureDisplayAwake(true, reason: "屏幕捕获运行中")
                    self.previewView.needsLayout = true
                    self.previewView.layoutSubtreeIfNeeded()
                    return
                }
                self.diagnosticLog.append("屏幕捕获启动失败; target=\(target.menuTitle); error=\(error.localizedDescription)")
                self.setStatus("屏幕捕获启动失败：\(error.localizedDescription)", base: false)
                self.failedScreenTargetIDs.insert(target.id)
                if self.pendingScreenTargetSpec != nil {
                    self.retryScreenTargetIfPossible()
                } else {
                    self.returnToSourceSelection(message: "所选来源无法捕获，请重新选择画面来源")
                }
            }
        }
    }

    /// 启动参数指定的窗口可能是启动器/加载中的临时窗口，窗口 ID 在列举与启动之间就会失效。
    /// 有目标规格时按退避重试，直到拿到一个稳定的窗口或达到上限。
    func retryScreenTargetIfPossible() {
        guard let spec = pendingScreenTargetSpec else { return }
        guard screenTargetAttempts < 8 else {
            pendingScreenTargetSpec = nil
            screenTargetAttempts = 0
            diagnosticLog.append("屏幕目标重试次数用尽; spec=\(spec)")
            returnToSourceSelection(message: "找不到可用的捕获窗口，请重新选择画面来源")
            return
        }
        screenTargetAttempts += 1
        let attempt = screenTargetAttempts
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.pendingScreenTargetSpec != nil else { return }
            self.diagnosticLog.append("重试屏幕目标; spec=\(spec); attempt=\(attempt)")
            self.reloadScreenTargets(userInitiated: false)
        }
    }

    func stopScreenCapture() {
        screenCaptureToken = UUID()
        guard let source = screenCaptureSource else { return }
        screenCaptureSource = nil
        source.stop()
    }

    func returnToSourceSelection(message: String) {
        guard videoSource == .screen, hasSelectedSource else { return }
        leaveGameOperationMode()
        diagnosticLog.append("屏幕来源失效，返回来源选择; \(message)")
        pendingScreenTargetSpec = nil
        pendingInterpolationMode = nil
        screenTargetAttempts = 0
        failedScreenTargetIDs.removeAll()
        stopScreenCapture()
        frameLock.lock()
        frameInterpolationEnabled = false
        frameLock.unlock()
        beginNewSourceGeneration(reason: "捕获来源已失效")
        frameInterpolationMenuItem.state = .off
        frameInterpolationMenuItem.title = "Apple 插帧"
        selectedScreenTarget = nil
        hasSelectedSource = false
        videoSource = .captureCard
        measuredFps = 0
        // The source picker must remain clickable even after an overlay session.
        isClickThrough = false
        window.ignoresMouseEvents = false
        clickThroughMenuItem.state = .off
        isAlwaysOnTop = false
        window.level = .normal
        floatMenuItem.state = .off
        setCaptureDisplayAwake(false, reason: "捕获来源已失效")
        refreshSourceMenu()
        window.orderOut(nil)
        setStatus("来源已断开", base: false)
        showConfiguration()
    }

    func refreshSourceMenu() {
        sourceMenu?.removeAllItems()
        guard let sourceMenu else { return }

        let cardItem = NSMenuItem(title: "采集卡（UVC / HDMI）",
                                  action: #selector(selectCaptureCardSource(_:)),
                                  keyEquivalent: "")
        cardItem.target = self
        cardItem.state = hasSelectedSource && videoSource == .captureCard ? .on : .off
        sourceMenu.addItem(cardItem)
        sourceMenu.addItem(.separator())

        guard ScreenCaptureSource.hasPermission || screenContentAccessConfirmed || screenTargetsLoading else {
            let request = NSMenuItem(title: "申请“屏幕录制”权限…",
                                     action: #selector(requestScreenPermission(_:)),
                                     keyEquivalent: "")
            request.target = self
            sourceMenu.addItem(request)
            let hint = NSMenuItem(title: "已开启仍不可用？移除旧条目后重新添加此 App",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sourceMenu.addItem(hint)
            let retry = NSMenuItem(title: "重新检查权限与来源", action: #selector(refreshScreenTargets(_:)), keyEquivalent: "")
            retry.target = self
            sourceMenu.addItem(retry)
            return
        }

        let header = NSMenuItem(title: "屏幕与窗口", action: nil, keyEquivalent: "")
        header.isEnabled = false
        sourceMenu.addItem(header)

        if screenTargets.isEmpty {
            let empty = NSMenuItem(title: screenTargetsLoading ? "正在读取…" : (screenTargetsError == nil ? "没有可捕获的目标" : "来源读取失败，请重新检查权限"),
                                   action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sourceMenu.addItem(empty)
        }
        for (index, target) in screenTargets.enumerated() {
            let item = NSMenuItem(title: target.menuTitle,
                                  action: #selector(selectScreenSource(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            if videoSource == .screen, selectedScreenTarget == target { item.state = .on }
            sourceMenu.addItem(item)
        }
        sourceMenu.addItem(.separator())
        let cropItem = NSMenuItem(title: "自动裁切顶部系统栏", action: #selector(toggleScreenAutoCrop(_:)), keyEquivalent: "")
        cropItem.target = self
        cropItem.state = autoCropScreenCapture ? .on : .off
        sourceMenu.addItem(cropItem)
        let refresh = NSMenuItem(title: "刷新列表",
                                 action: #selector(refreshScreenTargets(_:)), keyEquivalent: "")
        refresh.target = self
        sourceMenu.addItem(refresh)
    }

    @objc func toggleScreenAutoCrop(_ sender: Any?) {
        autoCropScreenCapture.toggle()
        UserDefaults.standard.set(autoCropScreenCapture, forKey: "autoCropScreenCapture")
        diagnosticLog.append("自动裁切开关; enabled=\(autoCropScreenCapture)")
        if videoSource == .screen, let target = selectedScreenTarget {
            startScreenCapture(target: target)
        } else { refreshSourceMenu() }
    }

    func reloadScreenTargets(userInitiated: Bool, completion: (() -> Void)? = nil) {
        guard !screenTargetsLoading else { return }
        screenTargetsLoading = true
        refreshSourceMenu()
        let excluded = ownWindowNumbers()
        ScreenCaptureSource.loadTargets(excludingWindowNumbers: excluded) { [weak self] targets, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.screenTargetsLoading = false
                self.screenContentAccessConfirmed = error == nil
                self.screenTargetsError = error?.localizedDescription
                self.screenTargets = targets
                self.refreshSourceMenu()
                if let error {
                    self.diagnosticLog.append("屏幕来源读取失败; preflight=\(ScreenCaptureSource.hasPermission); error=\(error)")
                    self.setStatus("无法读取屏幕来源；若权限已开启，请移除旧 SwitchViewer 条目后重新添加此 App", base: false)
                    completion?()
                    return
                }
                if let spec = self.pendingScreenTargetSpec {
                    if let target = self.resolveScreenTarget(spec) {
                        self.diagnosticLog.append("启动参数选择屏幕目标; spec=\(spec); target=\(target.menuTitle)")
                        // 规格保留到真正启动成功，失败时 retryScreenTargetIfPossible 会重新解析。
                        self.startScreenCapture(target: target)
                    } else {
                        self.diagnosticLog.append("暂时找不到屏幕目标; spec=\(spec)")
                        self.retryScreenTargetIfPossible()
                    }
                }
                if userInitiated {
                    self.setStatus("已刷新屏幕来源：\(targets.count) 个可选目标", base: false)
                }
                self.diagnosticLog.append("屏幕来源列表已更新; count=\(targets.count)")
                completion?()
            }
        }
    }

    @objc func selectCaptureCardSource(_ sender: Any) {
        // Listing devices never starts one; the user must choose a specific device.
        refreshDevices(selectPreferred: true, startIfSelected: false)
        deviceMenu.popUp(positioning: nil, at: NSPoint(x: 30, y: rootView.bounds.height - 30), in: rootView)
    }

    @objc func selectScreenSource(_ sender: NSMenuItem) {
        guard screenTargets.indices.contains(sender.tag) else { return }
        startScreenCapture(target: screenTargets[sender.tag])
    }

    @objc func refreshScreenTargets(_ sender: Any) {
        reloadScreenTargets(userInitiated: true)
    }

    @objc func requestScreenPermission(_ sender: Any) {
        ScreenCaptureSource.requestPermission()
        reloadScreenTargets(userInitiated: true)
    }

}
