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
    // MARK: Actions

    @objc func deviceChanged(_ sender: Any) {
        leaveGameOperationMode()
        markSourceSelected()
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

    @objc func showPerformanceToolbar(_ sender: Any) { gameInjectionController.show() }

    @objc func goFullscreen(_ sender: Any) { window.toggleFullScreen(nil) }

    @objc func toggleUniformProxyFrames(_ sender: Any) {
        frameLock.lock()
        uniformProxyFrames.toggle()
        let enabled = uniformProxyFrames
        frameLock.unlock()
        UserDefaults.standard.set(enabled, forKey: "uniformProxyFrames")
        uniformProxyMenuItem.state = enabled ? .on : .off
        diagnosticLog.append("原始帧代理缩放; enabled=\(enabled)")
        setStatus(enabled ? "Apple 代理插帧：所有帧统一清晰度" : "原始帧保留完整清晰度", base: false)
    }

    @objc func toggleFloat(_ sender: Any) {
        isAlwaysOnTop.toggle()
        floatMenuItem.state = isAlwaysOnTop ? .on : .off
        window.level = isAlwaysOnTop ? .floating : .normal
    }

    /// 屏幕捕获用来盖在游戏上时，窗口必须放行鼠标，否则点击会被预览窗吞掉。
    @objc func toggleClickThrough(_ sender: Any) {
        isClickThrough.toggle()
        window.ignoresMouseEvents = isClickThrough
        clickThroughMenuItem.state = isClickThrough ? .on : .off
        if isClickThrough, !isAlwaysOnTop {
            // 穿透后无法再用鼠标移动/关闭窗口，顺手置顶，避免被游戏盖住。
            isAlwaysOnTop = true
            floatMenuItem.state = .on
            window.level = .floating
        }
        setStatus(isClickThrough
                  ? "鼠标穿透已开启：点击与拖动会传给下层窗口，用菜单关闭"
                  : "鼠标穿透已关闭", base: false)
        diagnosticLog.append("鼠标穿透; enabled=\(isClickThrough)")
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
        applyFrameInterpolationMode(mode)
    }

    func applyFrameInterpolationMode(_ mode: FrameInterpolationMode) {
        if mode == .appleLowLatency || mode == .appleProxy {
            frameLock.lock()
            let width = lastWidth
            let height = lastHeight
            let pixelFormat = lastPixelFormat
            frameLock.unlock()
            let available = mode == .appleLowLatency
                ? canUseAppleLowLatencyFrame(width: width, height: height, pixelFormat: pixelFormat)
                : canUseAppleProxy(width: width, height: height, pixelFormat: pixelFormat)
            guard available else {
                updateAppleLowLatencyMenuAvailability()
                setStatus(mode == .appleLowLatency
                    ? "Apple 原生低延迟插帧需要 1920×1080 NV12 输入"
                    : "Apple 代理插帧需要至少 1024×576 的 NV12 输入", base: false)
                return
            }
        }
        frameLock.lock()
        guard frameInterpolationMode != mode else {
            frameLock.unlock()
            return
        }
        frameInterpolationMode = mode
        frameInterpolationEpoch += 1
        let epoch = frameInterpolationEpoch
        detectedGameFPS = nil
        observedContentFPS = nil
        clearDeadlineCadenceQualificationLocked()
        lastAcceptedSourceSignature = nil
        let engine = frameInterpolationEngine
        frameLock.unlock()
        presentationScheduler.reset(epoch: epoch)
        resetScreenTiming(epoch: epoch)
        engine?.setMode(mode)
        for item in frameInterpolationModeMenuItems {
            item.state = item.tag == mode.rawValue ? .on : .off
        }
        diagnosticLog.append("插帧方式切换; mode=\(mode.label)")
        setStatus("插帧方式：\(mode.label)", base: false)
    }

    @objc func selectPresentationPacing(_ sender: NSMenuItem) {
        guard videoSource != .screen else {
            setStatus("游戏窗口会自动匹配画面更新节奏，无需选择采集卡节奏", base: false)
            return
        }
        guard let mode = PresentationPacingMode(rawValue: sender.tag) else { return }
        frameLock.lock()
        guard presentationPacingMode != mode else {
            frameLock.unlock()
            return
        }
        presentationPacingMode = mode
        frameInterpolationEpoch += 1
        let epoch = frameInterpolationEpoch
        clearDeadlineCadenceQualificationLocked()
        frameLock.unlock()
        presentationScheduler.reset(epoch: epoch)
        resetScreenTiming(epoch: epoch)
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
            case .appleProxy:
                item.isEnabled = canUseAppleProxy(width: width, height: height,
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
        comparisonRecorder.stop()
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
                    onCadenceChanged: { [weak self] gameFPS in
                        guard let self else { return }
                        self.frameLock.lock()
                        let changed = self.detectedGameFPS != gameFPS
                        self.detectedGameFPS = gameFPS
                        if self.videoSource == .screen {
                            self.frameLock.unlock()
                            if changed {
                                self.diagnosticLog.append("屏幕内容更新率; observedFPS=\(gameFPS.map { String(format: "%.1f", $0) } ?? "预热中")")
                            }
                            return
                        }
                        let isDeadlineCadence = gameFPS.map { abs($0 - 30) <= 2 } ?? false
                        let schedulerSelected = self.interpolationOptions.usesLegacyTiming
                            && self.presentationPacingMode == .deadlineScheduled
                            && self.frameInterpolationMode == .appleProxy
                        var shouldResetScheduler = false
                        var schedulerResetReason: String?
                        if !schedulerSelected {
                            self.clearDeadlineCadenceQualificationLocked()
                        } else if isDeadlineCadence {
                            self.consecutiveNonDeadlineCadenceFrames = 0
                            if self.deadlineCadenceActive {
                                self.consecutiveDeadlineCadenceFrames = 0
                            } else {
                                self.consecutiveDeadlineCadenceFrames += 1
                                if self.consecutiveDeadlineCadenceFrames
                                    >= self.deadlineCadenceRecoveryFrames {
                                    self.deadlineCadenceActive = true
                                    self.consecutiveDeadlineCadenceFrames = 0
                                }
                            }
                        } else if self.deadlineCadenceActive {
                            self.consecutiveDeadlineCadenceFrames = 0
                            if gameFPS == nil {
                                self.consecutiveNonDeadlineCadenceFrames += 1
                                if self.consecutiveNonDeadlineCadenceFrames
                                    >= self.deadlineCadenceLossGraceFrames {
                                    self.deadlineCadenceActive = false
                                    self.consecutiveNonDeadlineCadenceFrames = 0
                                    shouldResetScheduler = true
                                    schedulerResetReason = "30fps 节奏连续未知 \(self.deadlineCadenceLossGraceFrames) 帧"
                                }
                            } else {
                                // A confidently detected cadence outside the scheduler's
                                // 30fps operating range is an immediate mode exit.
                                self.clearDeadlineCadenceQualificationLocked()
                                shouldResetScheduler = true
                                let cadenceLabel = gameFPS.map { String(format: "%.1f", $0) } ?? "未知"
                                schedulerResetReason = "检测到非 30fps 节奏 \(cadenceLabel)"
                            }
                        } else {
                            self.consecutiveNonDeadlineCadenceFrames = 0
                            self.consecutiveDeadlineCadenceFrames = 0
                        }
                        if shouldResetScheduler { self.frameInterpolationEpoch += 1 }
                        let schedulerEpoch = self.frameInterpolationEpoch
                        self.frameLock.unlock()
                        if shouldResetScheduler {
                            self.presentationScheduler.reset(epoch: schedulerEpoch,
                                                             preservingLearnedTiming: true)
                            self.diagnosticLog.append(
                                "deadline scheduler reset; 原因=\(schedulerResetReason ?? "未知"); preservingLearnedTiming=true")
                        }
                        if changed {
                            self.diagnosticLog.append(
                                "游戏节奏状态; gameFPS=\(gameFPS.map { String(format: "%.1f", $0) } ?? "未知")")
                        }
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
                newEngine?.setOptions(interpolationOptions)
                presentationScheduler.setOptions(interpolationOptions)
                screenPresentationScheduler.setOptions(interpolationOptions)
            } else {
                setStatus("系统插帧需要 macOS 26 或更新版本", base: false)
                return
            }
        }

        frameLock.lock()
        if let newEngine { frameInterpolationEngine = newEngine }
        frameInterpolationEnabled = shouldEnable
        frameInterpolationEpoch += 1
        let epoch = frameInterpolationEpoch
        detectedGameFPS = nil
        observedContentFPS = nil
        clearDeadlineCadenceQualificationLocked()
        lastAcceptedSourceSignature = nil
        frameInterpolationMenuItem.state = shouldEnable ? .on : .off
        let activeEngine = frameInterpolationEngine
        frameLock.unlock()
        presentationScheduler.reset(epoch: epoch)
        resetScreenTiming(epoch: epoch)
        activeEngine?.reset()

        let message = shouldEnable
            ? "实验性插帧已开启（\(frameInterpolationMode.label)，自动跳过重复游戏帧）"
            : "实验性插帧已关闭"
        diagnosticLog.append("帧插值开关; enabled=\(shouldEnable); mode=\(frameInterpolationMode.label)")
        setStatus(message, base: false)
    }

}
