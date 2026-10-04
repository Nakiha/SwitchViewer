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
    func allVideoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.devices(for: .video).filter(Self.isCaptureInput)
    }

    static func isCaptureInput(_ device: AVCaptureDevice) -> Bool {
        device.hasMediaType(.video) && device.deviceType != .builtInWideAngleCamera
            && device.deviceType != .deskViewCamera && !device.isContinuityCamera
    }

    func allAudioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.devices(for: .audio)
    }

    func refreshDevices(selectPreferred: Bool, startIfSelected: Bool = true) {
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
            setStatus("未发现采集卡，请检查 USB 连接", base: false)
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
        if startIfSelected && hasSelectedSource && videoSource == .captureCard,
           keepID == devicePopup.selectedItem?.representedObject as? String {
            rebuildFormatsAndStart()
        }
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
        markSourceSelected()
        // 任何采集卡操作都隐含"切回采集卡"，否则屏幕捕获会继续占用同一条链路。
        if videoSource == .screen {
            stopScreenCapture()
            videoSource = .captureCard
            selectedScreenTarget = nil
            refreshSourceMenu()
            diagnosticLog.append("切换画面来源; source=captureCard; reason=启动采集会话")
        }
        let gen = beginNewSourceGeneration(reason: "采集卡会话 \(video.localizedName)")
        let opt = formatOptions.indices.contains(formatIndex) ? formatOptions[formatIndex] : nil
        let requested = opt?.label ?? "未知格式[\(formatIndex)]"
        let initialAudioVolume = isMuted ? Float(0) : audioVolume
        diagnosticLog.append("请求启动采集会话; device=\(video.localizedName); requested=\(requested)")
        sessionQueue.async { [weak self] in
            guard let self, self.sessionGeneration == gen, self.hasSelectedSource else { return }
            self.setCaptureDisplayAwake(false, reason: "重新配置采集会话")
            // 1. 先停流：在运行中切格式会被静默吞掉（之前"请求/实际"对不上的主因）
            if self.session.isRunning { self.session.stopRunning() }
            if let locked = self.lockedFormatDevice {
                locked.unlockForConfiguration()
                self.lockedFormatDevice = nil
                self.diagnosticLog.append("停止旧流并释放设备格式锁; device=\(locked.localizedName)")
            }
            // 帧统计已由 beginNewSourceGeneration 重置。

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
                DispatchQueue.main.async {
                    guard self.sessionGeneration == gen, self.hasSelectedSource else { return }
                    self.stopCapture()
                    self.setStatus("打不开视频设备：\(error.localizedDescription)", base: false)
                    self.showConfiguration()
                }
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

}
