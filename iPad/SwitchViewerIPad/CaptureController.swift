import AVFoundation
import SwiftUI
import UIKit

struct CaptureChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

typealias CaptureFormat = CaptureVideoFormat

/// Only views showing live statistics observe this object. Capture menus observe the controller.
final class CaptureMetrics: ObservableObject {
    @Published var interpolationStatus = "插帧已关闭"
    @Published var sourceFPS = 0.0
    @Published var actualResolution = "未收到画面"
    @Published var contentFPS: Double?
    @Published var displayedFPS = 0.0
    @Published var midpointFPS = 0.0
    @Published var latency = 0.0
}

final class CaptureController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var devices: [CaptureChoice] = []
    @Published private(set) var formats: [CaptureFormat] = []
    @Published var selectedDeviceID = ""
    @Published var selectedFormatID = ""
    @Published private(set) var running = false
    @Published private(set) var demo = false
    @Published private(set) var status = "连接 HDMI USB 采集卡后，点击开始"
    @Published private(set) var soundEnabled = false
    @Published private(set) var soundStatus = "声音已关闭"
    @Published private(set) var interpolationEnabled = false
    let pipeline = FramePipeline()
    let metrics = CaptureMetrics()

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "switchviewer.ipad.capture", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "switchviewer.ipad.frames", qos: .userInteractive)
    private var demoTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var metricsTimer: Timer?
    private var requestID = UUID()
    private var wantsCapture = false
    private var wantsDemo = false
    private var active = true
    private var audioEngine: AVAudioEngine?
    private var soundRequestID = UUID()
    private let metricsLock = NSLock()
    private var shown = 0
    private var midpoints = 0
    private var ageSum = 0.0
    private var metricStart = CACurrentMediaTime()
    private var lastInputResolution = ""
    private var lastInputGeneration: UInt64 = .max

    override init() {
        super.init()
        pipeline.completionQueue = frameQueue
        pipeline.report = { [weak self] source, content, message in
            guard let self else { return }
            let generation = self.pipeline.frames.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pipeline.frames.generation == generation else { return }
                self.metrics.sourceFPS = source
                self.metrics.contentFPS = content
                self.metrics.interpolationStatus = message
            }
        }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.refreshDevices()
                if self.wantsCapture && !self.wantsDemo && self.active { self.startCapture() }
            })
        }
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.stopTransport()
            self?.status = "采集停止：\(error?.localizedDescription ?? "设备暂时不可用")。请重新开始。"
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.soundEnabled else { return }
            let hasUSB = AVAudioSession.sharedInstance().availableInputs?.contains { $0.portType == .usbAudio } ?? false
            if !hasUSB {
                self.stopAudio()
                self.soundEnabled = false
                self.soundStatus = "USB 音频已断开"
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopAudio()
            self?.soundEnabled = false
            self?.soundStatus = "声音被系统中断，可重新开启"
        })
        refreshDevices()
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.publishMetrics() }
    }

    deinit {
        metricsTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func refreshDevices() {
        let discovered = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video,
                                                          position: .unspecified).devices
        let choices = discovered.map { CaptureChoice(id: $0.uniqueID, name: $0.localizedName) }
        if devices != choices { devices = choices }
        if !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id ?? ""
        }
        refreshFormats()
    }

    func refreshFormats() {
        guard let device = videoDevice() else {
            if !formats.isEmpty { formats = [] }
            if !selectedFormatID.isEmpty { selectedFormatID = "" }
            return
        }
        var choices: [CaptureFormat] = []
        var seen: Set<String> = []
        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            // Include UHD / DCI 4K only when the UVC device actually advertises it.
            guard dimensions.width >= 640, dimensions.width <= 4096,
                  dimensions.height > 0, dimensions.height <= 2160 else { continue }
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            for fps in [60.0, 59.94, 50, 30, 29.97, 25] {
                let choice = CaptureFormat(width: dimensions.width, height: dimensions.height,
                                           fps: fps, subtype: subtype)
                guard format.videoSupportedFrameRateRanges.contains(where: {
                    choice.fits(minimumDuration: $0.minFrameDuration, maximumDuration: $0.maxFrameDuration)
                }) else { continue }
                if seen.insert(choice.id).inserted { choices.append(choice) }
            }
        }
        let ordered = choices.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            if $0.fps != $1.fps { return $0.fps > $1.fps }
            return $0.subtype < $1.subtype
        }
        if formats != ordered { formats = ordered }
        if !formats.contains(where: { $0.id == selectedFormatID }) {
            // Keep a low-latency default; 4K is an explicit quality choice.
            let preferred = formats.first { $0.width == 1920 && $0.height == 1080 && abs($0.fps - 60) < 0.1 }
            selectedFormatID = (preferred ?? formats.first)?.id ?? ""
        }
    }

    private func videoDevice() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.first { $0.uniqueID == selectedDeviceID }
    }

    func selectionChanged() {
        refreshFormats()
        if wantsCapture && !wantsDemo { startCapture() }
    }

    func formatChanged() { if wantsCapture && !wantsDemo { startCapture() } }

    func startCapture() {
        wantsCapture = true
        wantsDemo = false
        guard active else { return }
        if demo { stopTransport() }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureCapture()
        case .notDetermined:
            status = "等待采集卡访问权限"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.wantsCapture, !self.wantsDemo, self.active else { return }
                    if granted { self.refreshDevices(); self.configureCapture() }
                    else { self.status = "请在系统设置中允许 SwitchViewer 访问相机（采集卡）" }
                }
            }
        default: status = "请在系统设置中允许 SwitchViewer 访问相机（采集卡）"
        }
    }

    private func configureCapture() {
        stopAudio()
        guard let device = videoDevice() else {
            stopTransport()
            status = "未发现采集卡，连接后会自动重试"
            return
        }
        guard let choice = formats.first(where: { $0.id == selectedFormatID }) else {
            stopTransport()
            status = "采集卡未提供可用的视频模式"
            return
        }
        let token = UUID()
        requestID = token
        let enabled = interpolationEnabled
        status = "正在连接 \(device.localizedName)"
        demo = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.frameQueue.sync {
                self.demoTimer?.cancel(); self.demoTimer = nil
                self.pipeline.reset(interpolation: enabled)
            }
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            do {
                self.session.sessionPreset = .inputPriority
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw CaptureError.message("无法添加采集卡输入") }
                self.session.addInput(input)
                guard let format = device.formats.first(where: {
                    let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    return size.width == choice.width && size.height == choice.height &&
                        CMFormatDescriptionGetMediaSubType($0.formatDescription) == choice.subtype &&
                        $0.videoSupportedFrameRateRanges.contains {
                            choice.fits(minimumDuration: $0.minFrameDuration, maximumDuration: $0.maxFrameDuration)
                        }
                }) else { throw CaptureError.message("采集格式已失效，请重新选择") }
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = choice.frameDuration
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.automaticallyConfiguresOutputBufferDimensions = false
                output.deliversPreviewSizedOutputBuffers = false
                guard self.session.canAddOutput(output) else { throw CaptureError.message("无法添加采集视频输出") }
                self.session.addOutput(output)
                guard output.availableVideoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) else {
                    throw CaptureError.message("该采集卡无法输出 NV12 视频")
                }
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                output.setSampleBufferDelegate(self, queue: self.frameQueue)
                self.session.commitConfiguration()
                self.session.startRunning()
                let started = self.session.isRunning
                DispatchQueue.main.async {
                    guard self.requestID == token else { return }
                    self.running = started
                    self.status = started ? "\(device.localizedName) · \(choice.label)" : "采集卡未能启动，请重新连接"
                    UIApplication.shared.isIdleTimerDisabled = started
                    if started && self.soundEnabled { self.startAudio() }
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    guard self.requestID == token else { return }
                    self.running = false
                    self.status = error.localizedDescription
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }

    func stop() {
        wantsCapture = false
        wantsDemo = false
        soundRequestID = UUID()
        soundEnabled = false
        stopTransport()
        soundStatus = "声音已关闭"
        status = "已停止"
    }

    private func stopTransport() {
        requestID = UUID()
        soundRequestID = UUID()
        running = false
        demo = false
        stopAudio()
        UIApplication.shared.isIdleTimerDisabled = false
        metrics.sourceFPS = 0; metrics.contentFPS = nil; metrics.actualResolution = "未收到画面"
        let enabled = interpolationEnabled
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.frameQueue.sync {
                self.demoTimer?.cancel(); self.demoTimer = nil
                self.pipeline.reset(interpolation: enabled)
            }
        }
    }

    func setActive(_ active: Bool) {
        self.active = active
        if !active { stopTransport() }
        else if wantsCapture {
            if wantsDemo { startDemo() } else { startCapture() }
        }
    }

    func setInterpolation(_ enabled: Bool) {
        interpolationEnabled = enabled && FramePipeline.supportsInterpolation
        metrics.interpolationStatus = interpolationEnabled ? "插帧准备中" : "插帧已关闭"
        let selected = interpolationEnabled
        frameQueue.async { [weak self] in self?.pipeline.reset(interpolation: selected) }
    }

    func setSound(_ enabled: Bool) {
        let token = UUID()
        soundRequestID = token
        if !enabled { soundEnabled = false; stopAudio(); soundStatus = "声音已关闭"; return }
        guard running, !demo else { soundStatus = "请先连接采集卡并开始播放"; return }
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.soundRequestID == token else { return }
                if granted && self.running && !self.demo {
                    self.soundEnabled = true
                    self.startAudio()
                } else { self.soundStatus = "未开启声音，请检查麦克风权限和采集卡连接" }
            }
        }
    }

    private func startAudio() {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audio.setPreferredIOBufferDuration(0.005)
            try audio.setActive(true)
            guard let input = audio.availableInputs?.first(where: { $0.portType == .usbAudio }) else {
                throw CaptureError.message("未发现 USB 音频输入；采集卡需要支持 USB 音频")
            }
            try audio.setPreferredInput(input)
            if audio.currentRoute.outputs.contains(where: { $0.portType == .usbAudio }) {
                try audio.overrideOutputAudioPort(.speaker)
            }
            guard audio.currentRoute.inputs.contains(where: { $0.portType == .usbAudio }) else {
                throw CaptureError.message("无法切换到采集卡音频输入")
            }
            stopAudio(deactivate: false)
            let engine = AVAudioEngine()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.message("采集卡音频格式不可用") }
            engine.connect(engine.inputNode, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            audioEngine = engine
            soundStatus = "\(input.portName) · 声音播放中"
        } catch {
            stopAudio()
            soundEnabled = false
            soundStatus = error.localizedDescription
        }
    }

    private func stopAudio(deactivate: Bool = true) {
        audioEngine?.stop()
        audioEngine = nil
        if deactivate { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        processFrame(buffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // Called only on frameQueue, including the synthetic source.
    private func processFrame(_ buffer: CVPixelBuffer, pts: CMTime) {
        pipeline.receive(buffer, pts: pts)
        let resolution = "\(CVPixelBufferGetWidth(buffer))×\(CVPixelBufferGetHeight(buffer))"
        let generation = pipeline.frames.generation
        if resolution != lastInputResolution || generation != lastInputGeneration {
            lastInputResolution = resolution
            lastInputGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pipeline.frames.generation == generation else { return }
                self.metrics.actualResolution = resolution
            }
        }
    }

    func startDemo() {
        stopTransport()
        wantsCapture = true
        wantsDemo = true
        guard active else { return }
        demo = true
        soundRequestID = UUID()
        soundEnabled = false
        running = true
        status = "演示画面 · 1280×720 · 30 帧（无需采集卡）"
        soundStatus = "演示模式无声音"
        UIApplication.shared.isIdleTimerDisabled = true
        let enabled = interpolationEnabled
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameQueue.async { [weak self] in
                guard let self else { return }
                self.pipeline.reset(interpolation: enabled)
                var index: Int64 = 0
                let timer = DispatchSource.makeTimerSource(queue: self.frameQueue)
                timer.schedule(deadline: .now(), repeating: 1.0 / 30)
                timer.setEventHandler { [weak self] in
                    guard let self, let buffer = Self.demoBuffer(index: index) else { return }
                    self.processFrame(buffer, pts: CMTime(value: index, timescale: 30))
                    index += 1
                }
                self.demoTimer = timer
                timer.resume()
            }
        }
    }

    private static func demoBuffer(index: Int64) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                       kCVPixelBufferMetalCompatibilityKey as String: true]
        guard CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        memset(yBase, 32, stride * 720)
        memset(uvBase, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * 360)
        let x = Int(index * 16 % 1100)
        for row in 220..<500 { memset(yBase.advanced(by: row * stride + x), 210, 180) }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    func recordPresentation(at time: Double, receivedAt: Double, interpolated: Bool) {
        metricsLock.lock(); defer { metricsLock.unlock() }
        shown += 1
        if interpolated { midpoints += 1 }
        ageSum += max(0, time - receivedAt) * 1_000
    }

    private func publishMetrics() {
        metricsLock.lock()
        let now = CACurrentMediaTime()
        let elapsed = max(0.001, now - metricStart)
        let fps = Double(shown) / elapsed
        let midpointRate = Double(midpoints) / elapsed
        let age = shown > 0 ? ageSum / Double(shown) : 0
        shown = 0; midpoints = 0; ageSum = 0; metricStart = now
        metricsLock.unlock()
        metrics.displayedFPS = fps
        metrics.midpointFPS = midpointRate
        metrics.latency = age
    }

    private enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
