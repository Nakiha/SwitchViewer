import AppKit
import SwitchViewerInterpolation
import SwitchViewerGamePlugins
import SwitchViewerRecording

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
    private var exitRequestTimeout: DispatchWorkItem?
    private var lastDisplayUpdate = Date.distantPast
    private let onReport: (String) -> Void
    private var supportsTraceControl = false
    private var supportsInterpolationControl = false
    private var interpolationRequest: DispatchWorkItem?
    private var interpolationRequestPending = false
    private(set) var isGameInterpolationEnabled = true
    private(set) var interpolationPerformanceStatus = ""
    private(set) var interpolationControlStatus = ""
    var canToggleGameInterpolation: Bool { isGameRunning && supportsInterpolationControl && !interpolationRequestPending }

    private var configurationChannel: GameConfigurationChannel?
    private var supportsConfigurationControl = false
    private var configurationRequest: DispatchWorkItem?
    private var configurationSend: DispatchWorkItem?
    private var configurationRevision: UInt32 = 0
    private(set) var configurationRequestPending = false
    private(set) var appliedRuntimeConfiguration: GameRuntimeConfiguration?
    private(set) var gameConfigurationStatus = "运行中修改可即时生效。"
    var runningProcessID: Int32? { isGameRunning ? process?.processIdentifier : nil }
    var canChangeConfiguration: Bool { !comparisonRecordingBusy && !requestedStop }
    var desiredRuntimeConfiguration: GameRuntimeConfiguration {
        .init(interpolation: interpolationOptions, profile: interpolationProfile,
              displaySync: displaySyncEnabled, cadence: presentationCadence)
    }
    private func requestRuntimeConfiguration() {
        guard isGameRunning else { return }
        guard loaded else { gameConfigurationStatus = "等待游戏加载后应用设置…"; return }
        guard supportsConfigurationControl, let configurationChannel else {
            gameConfigurationStatus = "当前游戏使用旧版插帧库，重新启动游戏后可即时切换。"; return
        }
        configurationRevision &+= 1
        if configurationRevision == 0 { configurationRevision = 1 }
        let revision = configurationRevision
        configurationRequest?.cancel()
        configurationSend?.cancel()
        configurationRequestPending = true
        gameConfigurationStatus = "正在切换…" + (appliedRuntimeConfiguration.map { " 当前：" + $0.summary } ?? "")
        let desired = desiredRuntimeConfiguration, channelName = configurationChannel.name
        let send = DispatchWorkItem { [weak self] in
            guard let self, self.configurationRevision == revision, self.configurationChannel === configurationChannel else { return }
            self.configurationSend = nil
            do {
                try configurationChannel.send(desired, requestID: revision)
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.configurationRevision == revision, self.configurationRequestPending,
                          self.configurationChannel?.name == channelName else { return }
                    // A late acknowledgement remains authoritative. Until then,
                    // recording stays disabled to avoid mixing configurations.
                    self.gameConfigurationStatus = "游戏尚未确认切换。" + (self.appliedRuntimeConfiguration.map { " 当前：" + $0.summary } ?? "")
                    self.toolbar?.refreshConfiguration()
                }
                self.configurationRequest = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            } catch {
                self.configurationRequestPending = false
                self.gameConfigurationStatus = "无法发送配置：" + error.localizedDescription
                self.toolbar?.refreshConfiguration()
            }
        }
        configurationSend = send
        // Rapid control changes publish one complete final configuration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: send)
        toolbar?.refreshConfiguration()
    }
    private func consumeConfiguration(_ line: String) {
        guard let field = line.split(separator: " ").first(where: { $0.hasPrefix("value=") }),
              let value = UInt64(field.dropFirst(6)), let decoded = GameRuntimeConfiguration.decode(value) else { return }
        appliedRuntimeConfiguration = decoded.configuration
        if decoded.requestID == configurationRevision {
            configurationRequest?.cancel()
            configurationRequestPending = false
            interpolationPerformanceStatus = ""
            active = false
            toolbar?.resetMetrics()
            let failed = line.contains("CONFIGURATION failed")
            gameConfigurationStatus = (failed ? "切换失败，已保留：" : "已生效：") + decoded.configuration.summary
            if failed {
                // Roll the controls back to the acknowledged configuration.
                decoded.configuration.interpolation.save(prefix: "gameInterpolation")
                UserDefaults.standard.set(decoded.configuration.profile.rawValue, forKey: "gameInterpolationProfile")
                UserDefaults.standard.set(decoded.configuration.displaySync, forKey: "gameDisplaySyncEnabled")
                UserDefaults.standard.set(decoded.configuration.cadence.rawValue, forKey: "gamePresentationCadence")
                if let detail = line.split(separator: " ").first(where: { $0.hasPrefix("detail=") }),
                   let data = Data(base64Encoded: String(detail.dropFirst(7))), let message = String(data: data, encoding: .utf8) {
                    gameConfigurationStatus += "。" + message
                }
            } else if desiredRuntimeConfiguration != decoded.configuration { requestRuntimeConfiguration() }
        } else if configurationRequestPending {
            gameConfigurationStatus = "正在切换… 当前：" + decoded.configuration.summary
        }
        update(isGameInterpolationEnabled ? "配置已更新，等待新画面…" : "正在显示游戏原画面\n按 ⌥⇧I 恢复插帧")
    }

    private var supportsMovieControl = false
    private var movieRequest: DispatchWorkItem?
    private var movieArchivePending = false
    private let movieFolderAccess = GameRecordingFolderAccess()
    private var failedMovieArchive: (source: URL, root: URL)? { didSet { savePendingArchive() } }
    private(set) var recordingArchiveNeedsPermission = false { didSet { savePendingArchive() } }
    private func savePendingArchive() {
        if let failedMovieArchive {
            UserDefaults.standard.set(["source": failedMovieArchive.source.path, "root": failedMovieArchive.root.path,
                                       "needsPermission": recordingArchiveNeedsPermission], forKey: "pendingGameRecordingArchive")
        } else { UserDefaults.standard.removeObject(forKey: "pendingGameRecordingArchive") }
    }
    var canRetryRecordingArchive: Bool { failedMovieArchive != nil && !comparisonRecordingBusy }
    private var movieArchiveRoot = ComparisonMovieRecorder.recordingsDirectory()
    var onComparisonRecordingSettled: (() -> Void)?
    private(set) var isComparisonRecording = false
    private(set) var comparisonRecordingBusy = false
    private(set) var comparisonRecordingStatus = ""
    private(set) var comparisonRecordingDirectory: URL?
    var canRecordComparison: Bool {
        isGameRunning && supportsMovieControl && isGameInterpolationEnabled && !requestedStop && !comparisonRecordingBusy && !configurationRequestPending && failedMovieArchive == nil
    }
    func toggleComparisonRecording() {
        guard let process else { return }
        if isComparisonRecording {
            isComparisonRecording = false
            comparisonRecordingStatus = "正在保存…"
            GameMovieRecordingControl.request(processID: process.processIdentifier, start: false)
            return
        }
        guard canRecordComparison else { return }
        comparisonRecordingBusy = true
        comparisonRecordingStatus = "等待游戏开始录制…"
        GameMovieRecordingControl.request(processID: process.processIdentifier, start: true)
        let request = DispatchWorkItem { [weak self] in
            guard let self, !self.isComparisonRecording else { return }
            self.comparisonRecordingStatus = "游戏未响应录制请求，请重启游戏后重试"
            self.comparisonRecordingBusy = false
            self.onComparisonRecordingSettled?()
            // A late begin acknowledgement restores the actual recording state.
        }
        movieRequest = request
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: request)
    }
    private func consumeMovieRecord(_ line: String) {
        func decoded(_ key: String) -> String? {
            guard let field = line.split(separator: " ").first(where: { $0.hasPrefix(key + "=") }),
                  let data = Data(base64Encoded: String(field.dropFirst(key.count + 1))) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        movieRequest?.cancel()
        if line.contains("MOVIE_RECORD begin") {
            isComparisonRecording = true
            comparisonRecordingBusy = true
            comparisonRecordingStatus = "正在录制两路素材 · 最长 30 秒"
        } else if line.contains("MOVIE_RECORD finishing") {
            isComparisonRecording = false
            comparisonRecordingStatus = "正在保存…"
        } else if line.contains("MOVIE_RECORD end"), let path = decoded("path") {
            isComparisonRecording = false
            archiveMovie(from: URL(fileURLWithPath: path), to: movieArchiveRoot)
            return
        } else {
            isComparisonRecording = false
            comparisonRecordingBusy = false
            comparisonRecordingStatus = line.contains("MOVIE_RECORD end") ? "两路素材已保存"
                : "录制失败：" + (decoded("detail") ?? "未知原因")
        }
        if let path = decoded("path") { comparisonRecordingDirectory = URL(fileURLWithPath: path) }
        toolbar?.refreshConfiguration()
        if !comparisonRecordingBusy { onComparisonRecordingSettled?() }
    }

    private func archiveMovie(from source: URL, to root: URL, selectedAccess: URL? = nil) {
        comparisonRecordingBusy = true
        comparisonRecordingStatus = "正在转移到素材目录…"
        movieArchivePending = true
        recordingArchiveNeedsPermission = false
        comparisonRecordingDirectory = source
        let access = selectedAccess ?? movieFolderAccess.restoredAccess(for: source)
        // Capture only this attempt's URL; another recording cannot replace it.
        DispatchQueue.global(qos: .utility).async { [self] in
            let scoped = access?.startAccessingSecurityScopedResource() ?? false
            let result = Result { try ComparisonRecordingArchive.transfer(from: source, to: root) }
            if scoped { access?.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { [self] in
                movieArchivePending = false; comparisonRecordingBusy = false
                switch result {
                case .success(let saved):
                    failedMovieArchive = nil; recordingArchiveNeedsPermission = false
                    comparisonRecordingDirectory = saved.directory
                    comparisonRecordingStatus = saved.cleanupError == nil ? "两路素材已保存"
                        : "两路素材已保存；游戏内临时副本清理失败"
                case .failure(let error):
                    failedMovieArchive = (source, root)
                    recordingArchiveNeedsPermission = ComparisonRecordingArchive.needsSourceAuthorization(error, source: source)
                    comparisonRecordingStatus = recordingArchiveNeedsPermission
                        ? "素材已录好，但读取游戏素材目录需要授权。请点击“授权并转移”；原文件已保留。"
                        : "素材已录好，转移失败，原文件已保留：" + error.localizedDescription
                }
                toolbar?.refreshConfiguration()
                onComparisonRecordingSettled?()
            }
        }
        toolbar?.refreshConfiguration()
    }
    func retryRecordingArchive() {
        guard canRetryRecordingArchive, let failedMovieArchive else { return }
        if !recordingArchiveNeedsPermission {
            archiveMovie(from: failedMovieArchive.source, to: failedMovieArchive.root); return
        }
        comparisonRecordingBusy = true
        comparisonRecordingStatus = "等待授权读取素材目录…"
        movieArchivePending = true
        toolbar?.refreshConfiguration()
        movieFolderAccess.chooseAccess(for: failedMovieArchive.source) { [weak self] selected in
            guard let self else { return }
            self.comparisonRecordingBusy = false
            self.movieArchivePending = false
            guard let selected else {
                self.comparisonRecordingStatus = "授权已取消，素材仍保留在游戏目录，可再次点击“授权并转移”。"
                self.toolbar?.refreshConfiguration()
                self.onComparisonRecordingSettled?(); return
            }
            guard GameRecordingFolderAccess.accepts(selected, for: failedMovieArchive.source) else {
                self.comparisonRecordingStatus = "请选择这次素材文件夹或其上一级 Recordings 文件夹；原文件已保留。"
                self.toolbar?.refreshConfiguration()
                self.onComparisonRecordingSettled?(); return
            }
            self.archiveMovie(from: failedMovieArchive.source, to: failedMovieArchive.root, selectedAccess: selected)
        }
    }

    func toggleGameInterpolation() {
        guard !comparisonRecordingBusy, canToggleGameInterpolation, let process else { return }
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
        set { guard canChangeConfiguration else { return }; UserDefaults.standard.set(newValue, forKey: "gameDisplaySyncEnabled"); requestRuntimeConfiguration() }
    }

    var interpolationProfile: GameInterpolationProfile {
        get { GameInterpolationProfile(rawValue: UserDefaults.standard.string(forKey: "gameInterpolationProfile") ?? "") ?? .clarity }
        set { guard canChangeConfiguration else { return }; UserDefaults.standard.set(newValue.rawValue, forKey: "gameInterpolationProfile"); requestRuntimeConfiguration() }
    }
    var interpolationOptions: InterpolationOptions {
        get { InterpolationOptions.load(prefix: "gameInterpolation") }
        set { guard canChangeConfiguration else { return }; newValue.save(prefix: "gameInterpolation"); requestRuntimeConfiguration() }
    }
    var presentationCadence: GamePresentationCadence {
        get { .init(configuration: UserDefaults.standard.string(forKey: "gamePresentationCadence")) }
        set { guard canChangeConfiguration else { return }; UserDefaults.standard.set(newValue.rawValue, forKey: "gamePresentationCadence"); requestRuntimeConfiguration() }
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
        if let saved = UserDefaults.standard.dictionary(forKey: "pendingGameRecordingArchive"),
           let source = saved["source"] as? String, let root = saved["root"] as? String,
           UUID(uuidString: URL(fileURLWithPath: source).lastPathComponent) != nil {
            failedMovieArchive = (URL(fileURLWithPath: source), URL(fileURLWithPath: root))
            comparisonRecordingDirectory = failedMovieArchive?.source
            recordingArchiveNeedsPermission = (saved["needsPermission"] as? Bool) ?? true
            comparisonRecordingStatus = recordingArchiveNeedsPermission ? "上次素材尚未转移，请授权读取素材目录；原文件已保留。"
                : "上次素材尚未转移，可重试转移；原文件已保留。"
        }
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
    func refreshConfiguration() { toolbar?.refreshConfiguration() }

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

    @objc func startFixture() { startFixture(arguments: []) }
    func startFixture(arguments: [String]) {
        guard let executable = resource("GameHookFixture") else { update("找不到插帧测试程序，请重新构建应用。"); return }
        launch(executable: executable, name: "插帧测试窗口", plugin: GamePluginRegistry.builtIn.fallback, arguments: arguments)
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

    private func launch(executable: URL, name: String, plugin: any GameIntegrationPlugin, arguments: [String] = []) {
        guard #available(macOS 26.0, *) else { update("游戏内 Apple 插帧需要 macOS 26 或更新版本。"); return }
        guard process == nil else { update("请先退出本次启动的游戏。"); return }
        guard let library = resource("libSwitchViewerGameHook.dylib") else { update("找不到游戏内插帧库，请重新构建应用。"); return }
        onWillLaunch?()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        // Never propagate an unrelated injection chain into the target game.
        environment["DYLD_INSERT_LIBRARIES"] = library.path
        environment["SWITCHVIEWER_GAME_HOOK"] = "1"
        environment["SWITCHVIEWER_GAME_PLUGIN"] = plugin.descriptor.id
        environment["SWITCHVIEWER_GAME_PROFILE"] = interpolationProfile.rawValue
        environment["SWITCHVIEWER_GAME_MULTIPLIER"] = String(interpolationOptions.multiplier.rawValue)
        environment["SWITCHVIEWER_GAME_DELAY_MS"] = interpolationOptions.delayBudgetMilliseconds.map(String.init(describing:))
        environment["SWITCHVIEWER_GAME_DISPLAY_SYNC"] = displaySyncEnabled ? "1" : "0"
        environment["SWITCHVIEWER_GAME_CADENCE"] = presentationCadence.rawValue
        if executable.lastPathComponent == "GameHookFixture" {
            environment["SWITCHVIEWER_COMPARISON_RECORDING_ROOT"] = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/workflow-movies").path
            movieArchiveRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/workflow-movies-export")
        } else {
            movieArchiveRoot = ComparisonMovieRecorder.recordingsDirectory()
        }
        let identifier = UUID().uuidString
        configurationChannel = try? GameConfigurationChannel(identifier: identifier)
        environment["SWITCHVIEWER_GAME_CONFIGURATION_CHANNEL"] = configurationChannel == nil ? nil : identifier
        appliedRuntimeConfiguration = nil
        configurationRevision = 0
        gameConfigurationStatus = "等待游戏确认配置…"
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
                // Drain the final acknowledgement before discarding the log.
                while let data = try? self.logReader?.read(upToCount: 65_536), !data.isEmpty {
                    self.consume(String(decoding: data, as: UTF8.self))
                }
                self.finish()
                self.update(state == 0 ? "游戏已退出。" :
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
                // Detailed 8× trace can exceed one 64 KiB read per tick. Drain a
                // bounded batch so acknowledgements do not sit behind old frames.
                for _ in 0..<8 {
                    guard let data = try? self.logReader?.read(upToCount: 262_144), !data.isEmpty else { break }
                    self.consume(String(decoding: data, as: UTF8.self))
                    if data.count < 262_144 { break }
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
                supportsConfigurationControl = line.contains("configurationControl=notify-state-v1") && configurationChannel != nil
                if !supportsConfigurationControl { gameConfigurationStatus = "当前游戏使用旧版插帧库，重新启动游戏后可即时切换。" }
                supportsInterpolationControl = line.contains("interpolationControl=darwin-v1")
                confirmInterpolation(enabled: true)
                interpolationControlStatus = supportsInterpolationControl ? "" : "重启游戏以启用面板开关；当前可按 ⌥⇧I"
                supportsMovieControl = line.contains("movieControl=darwin-v1")
                if failedMovieArchive == nil { comparisonRecordingStatus = supportsMovieControl ? "" : "重启游戏以加载素材录制入口" }
                supportsTraceControl = line.contains("traceControl=darwin-v1")
                frameTraceStatus = supportsTraceControl ? "" : "重启游戏以加载记录入口"
                update("插帧库已加载，等待 Metal 游戏画面…")
            }
            else if let status = line.range(of: "INTERPOLATION_STATUS ") {
                interpolationPerformanceStatus = String(line[status.upperBound...])
            }
            else if line.contains("CONFIGURATION ") { consumeConfiguration(String(line)) }
            else if line.contains("MOVIE_RECORD ") { consumeMovieRecord(String(line)) }
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
                update("游戏内 Apple 插帧正在运行 · 目标 \(appliedRuntimeConfiguration?.interpolation.multiplier.label ?? interpolationOptions.multiplier.label)\n实际显示约 \(fps) fps")
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
        requestedStop = false
        exitRequestTimeout?.cancel()
        exitRequestTimeout = nil
        configurationSend?.cancel()
        configurationSend = nil
        configurationRequest?.cancel()
        configurationChannel = nil
        supportsConfigurationControl = false
        configurationRequestPending = false
        appliedRuntimeConfiguration = nil
        gameConfigurationStatus = "运行中修改可即时生效。"
        movieRequest?.cancel()
        supportsMovieControl = false
        if comparisonRecordingBusy && !movieArchivePending { comparisonRecordingStatus = "游戏退出前未确认录制保存，请检查素材目录" }
        isComparisonRecording = false
        comparisonRecordingBusy = movieArchivePending
        traceRequest?.cancel()
        traceRequestPending = false
        supportsTraceControl = false
        supportsInterpolationControl = false
        interpolationRequest?.cancel()
        interpolationRequestPending = false
        interpolationControlStatus = ""
        isGameInterpolationEnabled = true
        interpolationPerformanceStatus = ""
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
        if !comparisonRecordingBusy { onComparisonRecordingSettled?() }
    }
    @objc func stopGame() {
        guard !comparisonRecordingBusy else {
            comparisonRecordingStatus = "请先停止录制并等待保存，再退出游戏"
            toolbar?.refreshConfiguration(); return
        }
        guard let process, process.isRunning else { return }
        // Send the application's normal quit request. SIGTERM can enter a
        // game's engine teardown while its runtime is still using resources.
        requestedStop = true
        guard let application = NSRunningApplication(processIdentifier: process.processIdentifier),
              application.terminate() else {
            requestedStop = false
            update("无法请求游戏正常退出，请在游戏内退出。")
            return
        }
        update("已请求游戏正常退出…")
        exitRequestTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self, let process, self.process === process, process.isRunning else { return }
            self.requestedStop = false
            self.update("游戏尚未退出，请完成游戏内的退出提示，或在游戏内退出。")
        }
        exitRequestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }
    func shutdown() {
        exitRequestTimeout?.cancel()
        configurationSend?.cancel()
        configurationSend = nil
        configurationRequest?.cancel()
        configurationChannel = nil
        if comparisonRecordingBusy, let process {
            GameMovieRecordingControl.request(processID: process.processIdentifier, start: false)
        }
        movieRequest?.cancel()
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
