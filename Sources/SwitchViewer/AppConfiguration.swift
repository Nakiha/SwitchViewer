import AppKit
import AVFoundation

/// Configuration actions shared by the floating controls and preview window.
extension AppDelegate {
    func showConfiguration() { gameInjectionController.showSettings() }

    func showPreview() {
        guard hasSelectedSource else { showConfiguration(); return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    var selectedSourceName: String {
        if gameInjectionController.isGameRunning { return "游戏内插帧" }
        guard hasSelectedSource else { return "未选择来源" }
        return videoSource == .screen ? (selectedScreenTarget?.menuTitle ?? "屏幕")
            : (currentVideoDevice?.localizedName ?? "采集卡")
    }

    func startConfiguredDevice(id: String, formatIndex: Int) {
        guard let video = allVideoDevices().first(where: { $0.uniqueID == id }) else { return }
        leaveGameOperationMode()
        refreshDevices(selectPreferred: false, startIfSelected: false)
        if let index = (0..<devicePopup.numberOfItems).first(where: {
            devicePopup.item(at: $0)?.representedObject as? String == id
        }) { devicePopup.selectItem(at: index) }
        formatOptions = collectFormats(video)
        guard !formatOptions.isEmpty else { setStatus("设备没有可用格式", base: false); return }
        let index = min(max(0, formatIndex), formatOptions.count - 1)
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: formatOptions.map(\.label))
        formatPopup.selectItem(at: index)
        updateDeviceMenu()
        updateFormatMenu()
        startSession(video: video, formatIndex: index)
    }

    func setConfiguredCaptureFormat(_ option: FormatOption) {
        guard hasSelectedSource, videoSource == .captureCard,
              let id = currentVideoDevice?.uniqueID,
              let video = allVideoDevices().first(where: { $0.uniqueID == id }) else {
            setStatus("采集设备已断开，暂时无法修改分辨率", base: false)
            return
        }
        let available = collectFormats(video)
        guard let index = available.firstIndex(where: { $0.width == option.width && $0.height == option.height
            && $0.fps == option.fps && $0.subtype == option.subtype }) else {
            setStatus("该分辨率 / 帧率已不可用，请重新选择", base: false)
            return
        }
        formatOptions = available
        formatPopup.removeAllItems()
        formatPopup.addItems(withTitles: available.map(\.label))
        formatPopup.selectItem(at: index)
        updateFormatMenu()
        diagnosticLog.append("用户切换分辨率; device=\(video.localizedName); requested=\(option.label)")
        startSession(video: video, formatIndex: index)
    }

    func stopCapture() {
        leaveGameOperationMode()
        stopScreenCapture()
        hasSelectedSource = false
        frameLock.lock()
        frameInterpolationEnabled = false
        frameLock.unlock()
        beginNewSourceGeneration(reason: "停止来源")
        frameInterpolationMenuItem.state = .off
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning { session.stopRunning() }
            lockedFormatDevice?.unlockForConfiguration()
            lockedFormatDevice = nil
            setCaptureDisplayAwake(false, reason: "停止来源")
        }
        window.orderOut(nil)
        refreshSourceMenu()
        setStatus("已停止")
    }

    func setCaptureInterpolation(_ enabled: Bool) {
        if frameInterpolationEnabled != enabled { toggleFrameInterpolation(self) }
    }

    func setConfiguredPacing(_ rawValue: Int) {
        let item = NSMenuItem()
        item.tag = rawValue
        selectPresentationPacing(item)
    }
}
