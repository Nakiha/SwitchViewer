import AppKit
import SwitchViewerInterpolation
import SwitchViewerGamePlugins

/// Launch-time injection only: this controller never edits or re-signs the target.
final class GameInjectionController: NSObject, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var process: Process?
    private var logReader: FileHandle?
    private var logWriter: FileHandle?
    private var logTimer: Timer?
    private var timeout: DispatchWorkItem?
    
    private var pendingLog = ""
    private var loaded = false
    private(set) var status = "未运行"
    private(set) var runningGameName: String?
    private var active = false
    private var requestedStop = false
    private var lastDisplayUpdate = Date.distantPast
    private let onReport: (String) -> Void
    private var supportsTraceControl = false
    private var supportsInterpolationControl = false
    private var interpolationRequest: DispatchWorkItem?
    private var interpolationRequestPending = false
    private(set) var isGameInterpolationEnabled = true
    private(set) var interpolationControlStatus = ""
    var canToggleGameInterpolation: Bool { isGameRunning && supportsInterpolationControl && !interpolationRequestPending }

    func toggleGameInterpolation() {
        guard canToggleGameInterpolation, let process else { return }
        interpolationRequestPending = true
        interpolationControlStatus = "等待游戏确认…"
        GameInterpolationControl.request(processID: process.processIdentifier)
        let request = DispatchWorkItem { [weak self] in
            guard let self, self.interpolationRequestPending else { return }
            self.interpolationRequestPending = false
            self.interpolationControlStatus = "游戏未响应开关请求"
        }
        interpolationRequest?.cancel()
        interpolationRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: request)
    }
    private func confirmInterpolation(enabled: Bool) {
        interpolationRequest?.cancel()
        interpolationRequestPending = false
        isGameInterpolationEnabled = enabled
        interpolationControlStatus = ""
    }
    private var traceRequest: DispatchWorkItem?
    private var traceRequestPending = false
    private(set) var frameTraceStatus = ""
    private(set) var isFrameTraceRecording = false
    var canRecordGameFrames: Bool { process?.isRunning == true && supportsTraceControl && !traceRequestPending && !isFrameTraceRecording }

    var displaySyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gameDisplaySyncEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "gameDisplaySyncEnabled") }
    }

    var interpolationProfile: GameInterpolationProfile {
        get { GameInterpolationProfile(rawValue: UserDefaults.standard.string(forKey: "gameInterpolationProfile") ?? "") ?? .clarity }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gameInterpolationProfile") }
    }
    var presentationCadence: GamePresentationCadence {
        get { .init(configuration: UserDefaults.standard.string(forKey: "gamePresentationCadence")) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gamePresentationCadence") }
    }

    func recordGameFrames() {
        guard canRecordGameFrames, let process else { return }
        frameTraceStatus = "等待游戏确认…"
        traceRequestPending = true
        GameFrameTraceControl.request(processID: process.processIdentifier)
        let request = DispatchWorkItem { [weak self] in
            guard let self, self.traceRequestPending else { return }
            self.traceRequestPending = false
            self.frameTraceStatus = "游戏未响应记录请求"
        }
        traceRequest?.cancel()
        traceRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: request)
    }

    init(onReport: @escaping (String) -> Void) {
        self.onReport = onReport
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "SwitchViewer")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SwitchViewer · 点击显示/收起，右键打开菜单"
            button.setAccessibilityLabel("SwitchViewer 悬浮工具栏")
            button.target = self
            button.action = #selector(toggleToolbar)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func toggleToolbar() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control),
           let button = statusItem?.button {
            let menu = NSMenu()
            let show = NSMenuItem(title: "显示悬浮工具栏", action: #selector(showToolbarFromMenu), keyEquivalent: "")
            show.target = self
            menu.addItem(show)
            let sources = NSMenuItem(title: "设置…", action: #selector(showSourcesFromMenu), keyEquivalent: "")
            sources.target = self
            menu.addItem(sources)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出 SwitchViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        if toolbar?.isVisible == true { toolbar?.orderOut(nil) }
        else { show() }
    }

    @objc private func showToolbarFromMenu() { show() }
    @objc private func showSourcesFromMenu() { onShowSources?() }

    var onShowSources: (() -> Void)?
    var onCreateToolbar: ((PerformanceToolbar) -> Void)?
    var onWillLaunch: (() -> Void)?
    var isGameRunning: Bool { process != nil }
    private var toolbar: PerformanceToolbar?

    func show() {
        if let toolbar { toolbar.show(); return }
        let toolbar = PerformanceToolbar()
        onCreateToolbar?(toolbar)
        self.toolbar = toolbar
        self.panel = toolbar
        toolbar.show()
    }

    func showSettings() { show(); toolbar?.showTab(0) }
    func synchronizeWorkflow() { toolbar?.synchronizeWorkflow() }

    func receiveScreenMetrics(_ metrics: PerformanceMetrics) {
        guard process == nil else { return }
        toolbar?.receive(metrics)
    }

    private func resource(_ name: String) -> URL? {
        let candidates = [Bundle.main.privateFrameworksURL?.appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent("../../../.build/release/\(name)").standardizedFileURL]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    let gamePlugins = GamePluginRegistry.builtIn.plugins

    func startGame(pluginID: String, appURL: URL? = nil,
                   openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        guard let plugin = gamePlugins.first(where: { $0.descriptor.id == pluginID }) else {
            update("找不到该游戏插件，请重新选择。"); return
        }
        let installed = appURL ?? GamePluginRegistry.builtIn.installedApplication(for: plugin,
            isExecutableApplication: { url in
                guard let executable = Bundle(url: url)?.executableURL else { return false }
                return FileManager.default.isExecutableFile(atPath: executable.path)
            }, applicationForIdentifier: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
        guard let installed, let executable = Bundle(url: installed)?.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            let opened = plugin.descriptor.installationURLs.contains { openURL($0) }
            if plugin.descriptor.installationURLs.isEmpty {
                update("未找到 \(plugin.descriptor.name)，请安装游戏后重新启动。")
            } else {
                update(opened ? "未找到 \(plugin.descriptor.name)，已打开 App Store。安装完成后，回到这里启动游戏。"
                    : "未找到 \(plugin.descriptor.name)，无法打开 App Store，请在商店搜索并安装。")
            }
            return
        }
        launch(appURL: installed, plugin: plugin)
    }

    @objc func startFixture() {
        guard let executable = resource("GameHookFixture") else { update("找不到插帧测试程序，请重新构建应用。"); return }
        launch(executable: executable, name: "插帧测试窗口", plugin: GamePluginRegistry.builtIn.fallback)
    }

    private func launch(appURL: URL, plugin: any GameIntegrationPlugin) {
        guard let bundle = Bundle(url: appURL), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            update("找不到有效的游戏应用，请检查安装位置后重新启动。"); return
        }
        if let identifier = bundle.bundleIdentifier,
           !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
            update("请先正常退出 \(appURL.deletingPathExtension().lastPathComponent)，再从这里启动。"); return
        }
        launch(executable: executable, name: appURL.deletingPathExtension().lastPathComponent, plugin: plugin)
    }

    private func launch(executable: URL, name: String, plugin: any GameIntegrationPlugin) {
        guard #available(macOS 26.0, *) else { update("游戏内 Apple 插帧需要 macOS 26 或更新版本。"); return }
        guard process == nil else { update("请先退出本次启动的游戏。"); return }
        guard let library = resource("libSwitchViewerGameHook.dylib") else { update("找不到游戏内插帧库，请重新构建应用。"); return }
        onWillLaunch?()
        let child = Process()
        child.executableURL = executable
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        // Never propagate an unrelated injection chain into the target game.
        environment["DYLD_INSERT_LIBRARIES"] = library.path
        environment["SWITCHVIEWER_GAME_HOOK"] = "1"
        environment["SWITCHVIEWER_GAME_PLUGIN"] = plugin.descriptor.id
        environment["SWITCHVIEWER_GAME_PROFILE"] = interpolationProfile.rawValue
        environment["SWITCHVIEWER_GAME_DISPLAY_SYNC"] = displaySyncEnabled ? "1" : "0"
        environment["SWITCHVIEWER_GAME_CADENCE"] = presentationCadence.rawValue
        child.environment = environment
        let logDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/SwitchViewer/GameInjection", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let logURL = logDirectory.appendingPathComponent("\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            logWriter = try FileHandle(forWritingTo: logURL)
            logReader = try FileHandle(forReadingFrom: logURL)
            child.standardError = logWriter
        } catch { finish(); update("无法创建游戏接入日志：\(error.localizedDescription)"); return }
        child.standardOutput = FileHandle.nullDevice
        loaded = false
        active = false
        requestedStop = false
        lastDisplayUpdate = .distantPast
        pendingLog = ""
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === child else { return }
                let state = child.terminationStatus
                let wasLoaded = self.loaded
                let wasStopped = self.requestedStop
                self.finish()
                self.update(state == 0 || wasStopped ? "游戏已退出。" :
                    "游戏已退出（状态 \(state)）。\(wasLoaded ? "插帧库已加载，但未完成兼容性验证。" : "未确认加载成功，可能被系统或游戏保护阻止。")")
            }
        }
        do {
            process = child
            try child.run()
            runningGameName = name
            synchronizeWorkflow()
            // A regular file remains writable after the launcher exits, unlike a
            // pipe whose closed reader could deliver SIGPIPE to the game.
            logTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, weak child] _ in
                guard let self, self.process === child else { return }
                if let data = try? self.logReader?.read(upToCount: 65_536), !data.isEmpty {
                    self.consume(String(decoding: data, as: UTF8.self))
                }
                if self.active, Date().timeIntervalSince(self.lastDisplayUpdate) > 5 {
                    self.active = false
                    self.update("未收到新的显示帧，已暂时保留游戏原画面。")
                }
            }
            toolbar?.resetMetrics()
            update("正在启动 \(name)，等待游戏内插帧库响应…")
            let timeout = DispatchWorkItem { [weak self, weak child] in
                guard let self, self.process === child, !self.active else { return }
                self.update(self.loaded ? "插帧库已加载，但尚未确认生成帧。请等待游戏画面出现。" :
                    "未收到插帧库响应，本次未确认注入成功。可退出游戏后使用屏幕插帧模式。")
            }
            self.timeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        } catch { finish(); update("启动失败：\(error.localizedDescription)") }
    }

    private func consume(_ text: String) {
        pendingLog += text
        let lines = pendingLog.split(separator: "\n", omittingEmptySubsequences: false)
        pendingLog = String(lines.last ?? "")
        // 只匹配到标签为止：日志行在标签后面还带时间戳，写成 contains("[SwitchViewerHook]")
        // 会让前缀格式一改就整条链路静默失效（曾因此误报"未收到插帧库响应"）。
        for line in lines.dropLast() where line.contains("[SwitchViewerHook") {
            // Detailed timing stays in the inherited log file, not the live UI.
            if line.contains(" FRAME ") { continue }
            onReport(String(line))
            if line.contains("LOADED") {
                loaded = true
                supportsInterpolationControl = line.contains("interpolationControl=darwin-v1")
                confirmInterpolation(enabled: true)
                interpolationControlStatus = supportsInterpolationControl ? "" : "重启游戏以启用面板开关；当前可按 ⌥⇧I"
                supportsTraceControl = line.contains("traceControl=darwin-v1")
                frameTraceStatus = supportsTraceControl ? "" : "重启游戏以加载记录入口"
                update("插帧库已加载，等待 Metal 游戏画面…")
            }
            else if line.contains("FRAME_TRACE begin") {
                traceRequest?.cancel()
                traceRequestPending = false
                isFrameTraceRecording = true
                frameTraceStatus = "正在记录 · 30 秒"
            }
            else if line.contains("FRAME_TRACE end") {
                isFrameTraceRecording = false
                frameTraceStatus = "记录已保存"
            }
            else if line.contains("ACTIVE"), !active { update("已生成中间帧，正在确认实际显示…") }
            else if line.contains("METRICS") {
                let values = String(line).split(separator: " ").reduce(into: [String: Double]()) { result, field in
                    let pair = field.split(separator: "=")
                    if pair.count == 2, let value = Double(pair[1]) { result[String(pair[0])] = value }
                }
                if let fps = values["fps"], let latency = values["latencyP50"], let p95 = values["latencyP95"],
                   let wait = values["readyToDisplayP50"] {
                    let processing = values["processingP50"].flatMap { $0.isFinite ? $0 : nil }
                    var metrics = PerformanceMetrics(fps: fps, latency: latency, p95: p95, processing: processing, wait: wait)
                    metrics.originalAge = values["originalAgeP50"].flatMap { $0.isFinite ? $0 : nil }
                    metrics.sourceFPS = values["sourceFPS"].flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                    metrics.drawableWait = values["nextDrawableP50"]
                    metrics.gpu = values["submitToGPUCompleteP50"]
                    metrics.compositor = values["gpuCompleteToDisplayP50"]
                    toolbar?.receive(metrics)
                }
            }
            else if line.contains("DISPLAY") {
                let fpsValue = line.components(separatedBy: "outputFPS=").last.flatMap(Double.init) ?? 0
                guard fpsValue > 0 else { continue }
                active = true
                lastDisplayUpdate = Date()
                timeout?.cancel()
                let fps = line.components(separatedBy: "outputFPS=").last ?? "—"
                update("游戏内 Apple 插帧正在运行 · 目标 2×\n实际显示约 \(fps) fps")
            }
            else if line.contains("ERROR") { active = false; update("插帧暂不可用，保留游戏原画面。\n\(line.components(separatedBy: "] ").last ?? String(line))") }
            else if line.contains("PAUSED") { confirmInterpolation(enabled: false); active = false; toolbar?.resetMetrics(); update("正在显示游戏原画面\n按 ⌥⇧I 恢复插帧") }
            else if line.contains("RESUMED") { confirmInterpolation(enabled: true); update("已恢复插帧，等待新画面…") }
        }
        if pendingLog.utf8.count > 8192 { pendingLog = String(pendingLog.suffix(4096)) }
    }

    private func update(_ message: String) {
        status = message
        toolbar?.refreshConfiguration()
        onReport("游戏内插帧; \(message)") }
    private func finish() {
        traceRequest?.cancel()
        traceRequestPending = false
        supportsTraceControl = false
        supportsInterpolationControl = false
        interpolationRequest?.cancel()
        interpolationRequestPending = false
        interpolationControlStatus = ""
        isGameInterpolationEnabled = true
        isFrameTraceRecording = false
        frameTraceStatus = ""
        timeout?.cancel()
        timeout = nil
        logTimer?.invalidate()
        logTimer = nil
        try? logReader?.close()
        try? logWriter?.close()
        logReader = nil
        logWriter = nil
        process = nil
        runningGameName = nil
        synchronizeWorkflow()
        toolbar?.resetMetrics()
    }
    @objc func stopGame() { requestedStop = true; process?.terminate() }
    func shutdown() {
        interpolationRequest?.cancel()
        traceRequest?.cancel()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        // Leave the game running if SwitchViewer quits; injection ends when the game exits.
        timeout?.cancel()
        logTimer?.invalidate()
        try? logReader?.close()
        try? logWriter?.close()
        process?.terminationHandler = nil
    }
}
