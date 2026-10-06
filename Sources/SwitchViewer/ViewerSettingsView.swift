import AppKit
import AVFoundation
import SwitchViewerInterpolation

/// All user configuration lives here. Device discovery and capture remain in
/// the coordinators; this panel only edits values and invokes explicit actions.
final class ViewerSettingsView: NSView, NSMenuDelegate {
    private weak var owner: AppDelegate?
    private let discoverVideoDevices: () -> [AVCaptureDevice]
    private var deviceObservers: [NSObjectProtocol] = []
    private let sourceKinds = GlassChoiceControl(["采集卡", "窗口 / 屏幕"])
    private let gameProfile = NSPopUpButton()
    private let gameInterpolationOptions = InterpolationOptionsControl(identifier: "game-interpolation-options")
    private let captureInterpolationOptions = InterpolationOptionsControl(identifier: "capture-interpolation-options")
    private let gameConfigurationStatus = NSTextField(wrappingLabelWithString: "")
    private let gameInterpolationHealth = NSTextField(wrappingLabelWithString: "")
    private let captureInterpolationHealth = NSTextField(wrappingLabelWithString: "")
    private let gameCadence = NSPopUpButton()
    private let gameDisplaySync = NSButton(checkboxWithTitle: "垂直同步", target: nil, action: nil)
    private var cardLaunchers: NSStackView!
    private var captureButtons: [String: NSButton] = [:]
    private var formatDeviceID: String?
    private let format = NSPopUpButton()
    private let screenPicker = NSPopUpButton()
    private let backend = NSPopUpButton()
    private let color = NSPopUpButton()
    private let pacing = NSPopUpButton()
    private let interpolation = NSButton(checkboxWithTitle: "Apple 插帧", target: nil, action: nil)
    private let gameInterpolation = NSButton(checkboxWithTitle: "开启插帧", target: nil, action: nil)
    private let uniform = NSButton(checkboxWithTitle: "降低原帧清晰度以匹配插帧", target: nil, action: nil)
    private let crop = NSButton(checkboxWithTitle: "裁切顶部系统栏", target: nil, action: nil)
    private let mute = NSButton(checkboxWithTitle: "静音", target: nil, action: nil)
    private let volume = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let floating = NSButton(checkboxWithTitle: "预览窗口置顶", target: nil, action: nil)
    private let passthrough = NSButton(checkboxWithTitle: "鼠标点击穿过预览窗口", target: nil, action: nil)
    private let operation = NSButton(checkboxWithTitle: "全屏覆盖游戏画面", target: nil, action: nil)
    private var gameLaunchers: [NSButton] = []
    private var pageViews: [NSStackView] = []
    private var sourceViews: [NSStackView] = []
    private var gameProcessing: NSStackView!
    private var captureProcessing: NSStackView!
    private var captureOperations: NSView!
    private var captureFormatRow: NSStackView!
    private var gameShortcuts: NSStackView!
    private var captureShortcuts: NSStackView!
    private var captureTools: NSStackView!
    private var gameTools: NSStackView!
    private var captureRecovery: NSButton!
    private var startButton: NSButton!
    private var refreshButton: NSButton!
    private var gameToggle: NSButton!
    private let gameToggleStatus = NSTextField(labelWithString: "")
    private var movieButton: NSButton!
    private var movieFolderButton: NSButton!
    private let movieStatus = NSTextField(labelWithString: "")
    private var traceButton: NSButton!
    private let traceStatus = NSTextField(labelWithString: "")
    private var currentPage = 0
    private var sourceActions: NSStackView!
    private var contentStack: NSStackView!
    var onHeightChanged: ((CGFloat) -> Void)?
    private var timer: Timer?
    private var videos: [AVCaptureDevice] = []
    private var selectedFormats: [AppDelegate.FormatOption] = []
    private var deviceIDs: [String] = []
    private var targetIDs: [String] = []

    init(owner: AppDelegate, discoverVideoDevices: (() -> [AVCaptureDevice])? = nil) {
        self.owner = owner
        self.discoverVideoDevices = discoverVideoDevices ?? { [weak owner] in owner?.allVideoDevices() ?? [] }
        super.init(frame: .zero)
        let content = self
        sourceKinds.selection = owner.hasSelectedSource && owner.videoSource == .screen ? 1 : 0
        sourceKinds.onChange = { [weak self] _ in self?.selectSourceKind() }

        for health in [gameInterpolationHealth, captureInterpolationHealth, gameConfigurationStatus] {
            health.font = .systemFont(ofSize: 11); health.textColor = .secondaryLabelColor
        }
        gameInterpolationOptions.onChange = { [weak self] options in
            self?.owner?.gameInjectionController.interpolationOptions = options
            self?.refresh()
        }
        captureInterpolationOptions.onChange = { [weak self] options in
            self?.owner?.applyInterpolationOptions(options)
            self?.refresh()
        }
        gameConfigurationStatus.identifier = NSUserInterfaceItemIdentifier("game-configuration-status")
        gameProfile.identifier = NSUserInterfaceItemIdentifier("game-profile")
        gameDisplaySync.identifier = NSUserInterfaceItemIdentifier("game-display-sync")
        gameCadence.identifier = NSUserInterfaceItemIdentifier("game-cadence")
        gameProfile.addItems(withTitles: ["清晰优先（最高 1080p）", "速度优先（最高 720p）"])
        gameProfile.target = self
        gameProfile.action = #selector(changeGameProfile)
        gameProfile.toolTip = "设置生成帧的最高计算分辨率；720p 计算更快，1080p 细节更多。原帧保留原分辨率。运行中修改可即时生效。"
        gameDisplaySync.target = self
        gameDisplaySync.action = #selector(changeGameDisplaySync)
        gameDisplaySync.toolTip = "关闭可能缩短呈现等待，但可能撕裂。运行中修改可即时生效。"
        gameCadence.addItems(withTitles: GamePresentationCadence.allCases.map(\.label))
        gameCadence.target = self
        gameCadence.action = #selector(changeGameCadence)
        gameCadence.toolTip = "帧间隔均匀优先：减少帧集中显示，但可能增加等待；响应速度优先：尽快显示。关闭垂直同步时生效，运行中修改可即时生效。"
        gameProcessing = column([
            gameInterpolation, gameInterpolationOptions, gameInterpolationHealth,
            row("插帧偏好", gameProfile), row("显示同步", gameDisplaySync), row("显示节奏", gameCadence),
            gameConfigurationStatus
        ])
        let pluginLaunchers = owner.gameInjectionController.gamePlugins.map { plugin in
            let button = action(plugin.descriptor.name, #selector(startGamePlugin(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(plugin.descriptor.id)
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.toolTip = "启动 \(plugin.descriptor.name)；未安装时显示安装入口"
            return button
        }
        gameLaunchers = pluginLaunchers
        let gamePage = column([NSTextField(labelWithString: "选择游戏，启动后自动进入插帧面板。")]
            + gameLaunchers)
        let screenView = column([row("窗口 / 屏幕", screenPicker)])
        let cardView = column([])
        cardLaunchers = cardView
        sourceViews = [cardView, screenView]
        startButton = action("开始采集", #selector(startSource))
        refreshButton = action("刷新来源", #selector(refreshSources))
        sourceActions = horizontal([startButton, refreshButton])
        let sourcePage = column([NSTextField(labelWithString: "选择视频输入，开始后打开画面窗口。"),
                                 sourceKinds, cardView, screenView, sourceActions])

        format.addItem(withTitle: "没有可用格式")
        screenPicker.addItem(withTitle: "请选择来源")
        format.identifier = NSUserInterfaceItemIdentifier("capture-format")
        format.menu?.delegate = self
        backend.addItems(withTitles: FrameInterpolationMode.allCases.map(\.label))
        color.addItems(withTitles: ColorMode.allCases.map(\.label))
        pacing.addItems(withTitles: PresentationPacingMode.allCases.map(\.label))
        backend.toolTip = "两种方式都使用 Apple 插帧。直接插帧仅接受 1920×1080 NV12；缩放插帧会把高分辨率画面缩到最高 1080p 计算，再放大显示，生成帧的细节会减少。"
        pacing.toolTip = "按画面更新节奏显示：限制帧显示速度，减少帧集中出现；即时显示：画面准备好便提交；按视频时间显示：根据视频时间戳安排显示。后两项为实验选项。"
        color.toolTip = "通常保持自动。BT.709 / BT.601 是色彩转换标准；视频范围为有限亮度范围，全范围使用完整亮度范围。颜色或黑白明暗不正常时，按采集源输出格式选择。"
        uniform.toolTip = "仅缩放插帧时生效。降低原帧细节，减少原帧与生成帧交替时的清晰度跳变；关闭后原帧保留原始清晰度。"
        passthrough.toolTip = "点击预览窗口时，鼠标事件会交给后面的窗口。"
        operation.toolTip = "将处理后的画面全屏覆盖在所选游戏上，并把键盘与鼠标操作交给游戏。仅支持游戏窗口采集。"
        captureFormatRow = field("分辨率 / 帧率", format)
        format.toolTip = "选择后立即重新配置采集，会短暂中断画面。"
        let audiovisual = section("音视频配置", [captureFormatRow, field("色彩", color), field("显示节奏", pacing),
                                field("采集卡音频", horizontal([mute, volume]))])
        let previewOptions = section("操作配置", [crop, floating, passthrough, operation,
            horizontal([action("显示画面", #selector(showPreview)), action("全屏", #selector(fullscreen))])])
        let frameGeneration = section("插帧配置", [interpolation, field("插帧方式", backend), captureInterpolationOptions, captureInterpolationHealth, uniform])
        let operationsColumn = topAligned(previewOptions)
        captureOperations = operationsColumn
        let interpolationColumn = topAligned(frameGeneration)
        captureProcessing = horizontal([audiovisual, operationsColumn, interpolationColumn])
        captureProcessing.distribution = .fillEqually
        captureProcessing.alignment = .top
        captureProcessing.spacing = 24
        let picturePage = column([gameProcessing, captureProcessing])
        traceButton = action("记录 30 秒", #selector(recordGameFrames))
        traceButton.toolTip = "记录游戏插帧各阶段的逐帧时序"
        traceStatus.font = .systemFont(ofSize: 11)
        traceStatus.textColor = .secondaryLabelColor
        captureTools = horizontal([action("保存截图", #selector(screenshot)), action("导出诊断", #selector(diagnostics))])
        gameTools = horizontal([traceButton])
        captureRecovery = action("重试渲染", #selector(retryRenderer))
        movieButton = action("录制对比素材", #selector(recordComparisonMovie))
        movieButton.toolTip = "同时录制原始帧和处理后帧，最长 30 秒。不含音频、工具栏与最终显示着色；用于剪辑对比。"
        movieFolderButton = action("打开素材", #selector(openComparisonMovies))
        movieStatus.font = .systemFont(ofSize: 11)
        movieStatus.textColor = .secondaryLabelColor
        let movieRow = horizontal([movieButton, movieFolderButton, NSView()])
        let toolsRow = horizontal([
            captureTools, gameTools, action("打开日志", #selector(logs)), captureRecovery,
            action("退出 SwitchViewer", #selector(quitApplication)), NSView()
        ])
        toolsRow.identifier = NSUserInterfaceItemIdentifier("tools-actions")
        toolsRow.alignment = .centerY
        toolsRow.spacing = 12
        let toolsPage = column([movieRow, movieStatus, toolsRow, traceStatus])
        gameToggle = action("关闭插帧", #selector(toggleGameInterpolation))
        gameToggleStatus.font = .systemFont(ofSize: 11)
        gameToggleStatus.textColor = .secondaryLabelColor
        gameShortcuts = column([
            row("⌥⇧I", horizontal([gameToggle, gameToggleStatus])),
            row("⌥⇧T", NSTextField(labelWithString: "记录 30 秒逐帧时序")),
            NSTextField(labelWithString: "快捷键在游戏窗口获得焦点时生效；面板按钮可直接操作。")
        ])
        captureShortcuts = column([
            row("I", NSTextField(labelWithString: "开启 / 关闭插帧")),
            row("F / S / D", NSTextField(labelWithString: "全屏 / 保存截图 / 导出诊断")),
            row("M / C / R", NSTextField(labelWithString: "静音 / 切换色彩 / 重试渲染")),
            NSTextField(labelWithString: "快捷键在画面窗口获得焦点时生效。")
        ])
        let shortcutsPage = column([gameShortcuts, captureShortcuts])
        pageViews = [sourcePage, gamePage, picturePage, shortcutsPage, toolsPage]
        let body = column(pageViews)
        let stack = column([body])
        contentStack = stack
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 0),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: 0),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for control in [format, backend, color, pacing] { control.target = self; control.action = #selector(changeValue(_:)) }
        for button in [interpolation, gameInterpolation, uniform, crop, mute, floating, passthrough, operation] { button.target = self; button.action = #selector(changeToggle(_:)) }
        volume.target = self; volume.action = #selector(changeVolume)
        volume.isContinuous = true
        selectPage(0)
        selectSourceKind()
        deviceObservers = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let changed = notification.object as? AVCaptureDevice, changed.hasMediaType(.video) else { return }
                self?.refresh()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit {
        timer?.invalidate()
        for observer in deviceObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func activate() {
        if currentPage == 0 {
            refreshDevices()
            loadScreenSourcesIfAuthorized()
        }
        refresh()
        if timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !isHidden, window?.isVisible == true else { return }
            refresh()
        } }
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        for view in views where view is NSStackView { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    private func horizontal(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.spacing = 8; return stack }
    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let stack = column([heading] + views)
        stack.distribution = .fill
        stack.setHuggingPriority(.required, for: .vertical)
        stack.identifier = NSUserInterfaceItemIdentifier(title)
        return stack
    }
    private func topAligned(_ content: NSStackView) -> NSView {
        let holder = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: holder.topAnchor),
            content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: holder.bottomAnchor)
        ])
        return holder
    }
    private func field(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        let stack = column([label, control])
        stack.spacing = 6
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }
    private func row(_ name: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true
        let stack = horizontal([label, control])
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }
    private func action(_ title: String, _ selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        button.bezelStyle = .rounded
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }
        return button
    }
    func selectPage(_ index: Int) {
        currentPage = index
        for (i, view) in pageViews.enumerated() { view.isHidden = i != index }
        refresh()
    }
    private func updateHeight() {
        // Hidden workflow controls and inactive tabs do not reserve space.
        // Keep only a small bottom inset around the visible content.
        onHeightChanged?(ceil(contentStack.fittingSize.height) + 8)
    }
    private func selectSourceKind() {
        for (i, view) in sourceViews.enumerated() { view.isHidden = i != sourceKinds.selection }
        sourceActions.isHidden = sourceKinds.selection == 0
        loadScreenSourcesIfAuthorized()
        refresh()
    }
    private func loadScreenSourcesIfAuthorized() {
        guard currentPage == 0, sourceKinds.selection == 1, let owner,
              ScreenCaptureSource.hasPermission || owner.screenContentAccessConfirmed else { return }
        owner.reloadScreenTargets(userInitiated: false) { [weak self] in self?.refresh() }
    }
    private func refreshDevices() {
        guard let owner else { return }
        owner.refreshDevices(selectPreferred: true, startIfSelected: false)
        synchronizeDeviceChoices()
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func synchronizeDeviceChoices() {
        guard let owner else { return }
        let activeID = owner.hasSelectedSource && owner.videoSource == .captureCard ? owner.currentVideoDevice?.uniqueID : nil
        videos = discoverVideoDevices().filter(AppDelegate.isCaptureInput)
        let ids = videos.map(\.uniqueID)
        let changed = ids != deviceIDs || videos.contains { captureButtons[$0.uniqueID]?.title != $0.localizedName }
            || cardLaunchers.arrangedSubviews.isEmpty
        if changed {
            deviceIDs = ids
            for view in cardLaunchers.arrangedSubviews {
                cardLaunchers.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            captureButtons.removeAll()
            if videos.isEmpty {
                let empty = NSTextField(labelWithString: "未发现采集卡，请连接 USB 采集卡。")
                empty.textColor = .secondaryLabelColor
                cardLaunchers.addArrangedSubview(empty)
            } else {
                for video in videos {
                    let button = action(video.localizedName, #selector(startCaptureCard(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier("capture-launch")
                    button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
                    button.imagePosition = .imageLeading
                    button.toolTip = "打开 \(video.localizedName) 的采集窗口"
                    captureButtons[video.uniqueID] = button
                    cardLaunchers.addArrangedSubview(button)
                }
            }
        }
        let newFormatID = activeID ?? videos.first?.uniqueID
        if changed || newFormatID != formatDeviceID {
            formatDeviceID = newFormatID
            refreshFormats(preserveSelection: true)
        }
        for button in captureButtons.values { button.isEnabled = !owner.gameInjectionController.isGameRunning }
        format.isEnabled = !selectedFormats.isEmpty
    }
    private func refreshFormats(preserveSelection: Bool = false) {
        guard let owner else { return }
        let current = owner.hasSelectedSource && owner.videoSource == .captureCard
            && owner.formatOptions.indices.contains(owner.formatPopup.indexOfSelectedItem)
            ? owner.formatOptions[owner.formatPopup.indexOfSelectedItem] : nil
        let previous = current ?? (preserveSelection && selectedFormats.indices.contains(format.indexOfSelectedItem)
            ? selectedFormats[format.indexOfSelectedItem] : nil)
        selectedFormats = videos.first(where: { $0.uniqueID == formatDeviceID }).map(owner.collectFormats) ?? []
        format.removeAllItems()
        format.addItems(withTitles: selectedFormats.isEmpty ? ["没有可用格式"] : selectedFormats.map(\.label))
        let preferred = selectedFormats.firstIndex { $0.width == 3840 && abs($0.fps - 60) < 1 } ?? 0
        let preserved = previous.flatMap { old in selectedFormats.firstIndex {
            $0.width == old.width && $0.height == old.height && $0.fps == old.fps && $0.subtype == old.subtype
        } }
        if !selectedFormats.isEmpty { format.selectItem(at: preserved ?? preferred) }
        format.isEnabled = !selectedFormats.isEmpty
    }
    func refresh() {
        guard let owner, !pageViews.isEmpty else { return }
        let gameRunning = owner.gameInjectionController.isGameRunning
        let cardRunning = !gameRunning && owner.hasSelectedSource && owner.videoSource == .captureCard
        if currentPage == 0 || (currentPage == 2 && cardRunning) { synchronizeDeviceChoices() }
        captureFormatRow.isHidden = !cardRunning
        captureOperations.isHidden = cardRunning
        // The menu bar can also change the capture format; reflect its selection.
        if cardRunning, owner.formatOptions.indices.contains(owner.formatPopup.indexOfSelectedItem) {
            let configured = owner.formatOptions[owner.formatPopup.indexOfSelectedItem]
            if let index = selectedFormats.firstIndex(where: { $0.width == configured.width && $0.height == configured.height
                && $0.fps == configured.fps && $0.subtype == configured.subtype }) { format.selectItem(at: index) }
        }
        gameProcessing.isHidden = !gameRunning
        captureProcessing.isHidden = gameRunning
        gameShortcuts.isHidden = !gameRunning
        captureShortcuts.isHidden = gameRunning
        gameTools.isHidden = !gameRunning
        captureTools.isHidden = gameRunning
        captureRecovery.isHidden = gameRunning
        let ids = owner.screenTargets.map(\.menuTitle)
        if ids != targetIDs {
            let selected = screenPicker.indexOfSelectedItem
            targetIDs = ids; screenPicker.removeAllItems(); screenPicker.addItems(withTitles: ids)
            if !ids.isEmpty { screenPicker.selectItem(at: min(max(0, selected), ids.count - 1)) }
        }
        gameConfigurationStatus.stringValue = owner.gameInjectionController.gameConfigurationStatus
        gameInterpolationHealth.stringValue = owner.gameInjectionController.interpolationPerformanceStatus
        gameInterpolationHealth.isHidden = gameInterpolationHealth.stringValue.isEmpty || !owner.gameInjectionController.isGameInterpolationEnabled
        captureInterpolationHealth.stringValue = owner.interpolationPerformanceStatus
        captureInterpolationHealth.isHidden = captureInterpolationHealth.stringValue.isEmpty || !owner.frameInterpolationEnabled
        gameInterpolationOptions.update(owner.gameInjectionController.interpolationOptions)
        captureInterpolationOptions.update(owner.interpolationOptions)
        gameInterpolationOptions.setControlsEnabled(!owner.gameInjectionController.comparisonRecordingBusy)
        captureInterpolationOptions.setControlsEnabled(!gameRunning && !owner.comparisonRecorder.isBusy)
        gameProfile.selectItem(at: owner.gameInjectionController.interpolationProfile == .lowLatency ? 1 : 0)
        gameProfile.isEnabled = owner.gameInjectionController.canChangeConfiguration
        gameDisplaySync.state = owner.gameInjectionController.displaySyncEnabled ? .on : .off
        gameDisplaySync.isEnabled = owner.gameInjectionController.canChangeConfiguration
        gameCadence.selectItem(at: GamePresentationCadence.allCases.firstIndex(of: owner.gameInjectionController.presentationCadence) ?? 0)
        gameToggle.title = owner.gameInjectionController.isGameInterpolationEnabled ? "关闭插帧" : "开启插帧"
        gameToggle.isEnabled = owner.gameInjectionController.canToggleGameInterpolation && !owner.gameInjectionController.comparisonRecordingBusy
        gameToggleStatus.stringValue = gameRunning ? owner.gameInjectionController.interpolationControlStatus : "未运行游戏"
        let movieBusy = gameRunning ? owner.gameInjectionController.comparisonRecordingBusy : owner.comparisonRecorder.isBusy
        let recording = gameRunning ? owner.gameInjectionController.isComparisonRecording : owner.comparisonRecorder.isRecording
        movieButton.title = recording ? "停止录制" : (movieBusy ? "正在保存…" : "录制对比素材")
        movieButton.isEnabled = recording || (!movieBusy && (gameRunning
            ? owner.gameInjectionController.canRecordComparison : owner.hasSelectedSource && owner.frameInterpolationEnabled))
        movieFolderButton.isEnabled = (gameRunning ? owner.gameInjectionController.comparisonRecordingDirectory : owner.comparisonRecordingDirectory) != nil
        movieStatus.stringValue = gameRunning ? owner.gameInjectionController.comparisonRecordingStatus : owner.comparisonRecordingStatus
        movieStatus.isHidden = movieStatus.stringValue.isEmpty
        traceButton.isEnabled = owner.gameInjectionController.canRecordGameFrames
        traceStatus.stringValue = owner.gameInjectionController.frameTraceStatus
        traceStatus.isHidden = !gameRunning || traceStatus.stringValue.isEmpty
        gameLaunchers.forEach { $0.isEnabled = !gameRunning }
        gameCadence.isEnabled = !owner.gameInjectionController.displaySyncEnabled && owner.gameInjectionController.canChangeConfiguration
        startButton.isEnabled = !gameRunning && (sourceKinds.selection == 1 ? !ids.isEmpty : !selectedFormats.isEmpty)
        refreshButton.title = sourceKinds.selection == 1 && !ScreenCaptureSource.hasPermission && !owner.screenContentAccessConfirmed ? "授权屏幕录制" : "刷新来源"
        backend.selectItem(at: FrameInterpolationMode.allCases.firstIndex(of: owner.frameInterpolationMode) ?? 1)
        color.selectItem(at: owner.renderer?.colorMode.rawValue ?? 0)
        pacing.selectItem(at: owner.presentationPacingMode.rawValue)
        interpolation.state = owner.frameInterpolationEnabled ? .on : .off
        gameInterpolation.state = owner.gameInjectionController.isGameInterpolationEnabled ? .on : .off
        uniform.state = owner.uniformProxyFrames ? .on : .off
        crop.state = owner.autoCropScreenCapture ? .on : .off
        mute.state = owner.isMuted ? .on : .off
        floating.state = owner.isAlwaysOnTop ? .on : .off
        passthrough.state = owner.isClickThrough ? .on : .off
        operation.state = owner.gameOverlayPanel != nil ? .on : .off
        volume.doubleValue = Double(owner.audioVolume)
        interpolation.isEnabled = owner.hasSelectedSource && !owner.frameInterpolationUnavailable
        gameInterpolation.isEnabled = owner.gameInjectionController.canToggleGameInterpolation && !owner.gameInjectionController.comparisonRecordingBusy
        interpolation.title = "开启插帧"
        gameInterpolation.toolTip = owner.gameInjectionController.interpolationControlStatus
        backend.isEnabled = owner.hasSelectedSource && !gameRunning
        uniform.isEnabled = owner.hasSelectedSource && owner.frameInterpolationMode == .appleProxy
        pacing.isEnabled = owner.hasSelectedSource && owner.videoSource == .captureCard && owner.interpolationOptions.usesLegacyTiming
        color.isEnabled = owner.hasSelectedSource && !gameRunning
        crop.isEnabled = owner.hasSelectedSource && owner.videoSource == .screen
        for control in [floating, passthrough, operation] { control.isEnabled = owner.hasSelectedSource }
        mute.isEnabled = owner.hasSelectedSource && owner.videoSource == .captureCard
        volume.isEnabled = mute.isEnabled
        updateHeight()
    }
    @objc private func changeGameDisplaySync() {
        guard let owner else { return }
        owner.gameInjectionController.displaySyncEnabled = gameDisplaySync.state == .on
        refresh()
    }
    @objc private func changeGameProfile() {
        guard let owner else { return }
        owner.gameInjectionController.interpolationProfile = gameProfile.indexOfSelectedItem == 1 ? .lowLatency : .clarity
        refresh()
    }
    @objc private func changeGameCadence() {
        guard let owner,
              GamePresentationCadence.allCases.indices.contains(gameCadence.indexOfSelectedItem) else { return }
        owner.gameInjectionController.presentationCadence = GamePresentationCadence.allCases[gameCadence.indexOfSelectedItem]
        refresh()
    }
    @objc private func changeValue(_ sender: NSPopUpButton) {
        guard let owner else { return }
        if sender === format, selectedFormats.indices.contains(sender.indexOfSelectedItem) {
            owner.setConfiguredCaptureFormat(selectedFormats[sender.indexOfSelectedItem])
        }
        else if sender === backend, FrameInterpolationMode.allCases.indices.contains(sender.indexOfSelectedItem) { owner.applyFrameInterpolationMode(FrameInterpolationMode.allCases[sender.indexOfSelectedItem]) }
        else if sender === color, let mode = ColorMode(rawValue: sender.indexOfSelectedItem) { owner.applyColorMode(mode) }
        else if sender === pacing { owner.setConfiguredPacing(sender.indexOfSelectedItem) }
        refresh()
    }
    @objc private func changeToggle(_ sender: NSButton) {
        guard let owner else { return }
        if sender === interpolation { owner.setCaptureInterpolation(sender.state == .on) }
        else if sender === gameInterpolation { owner.gameInjectionController.toggleGameInterpolation() }
        else if sender === uniform { owner.toggleUniformProxyFrames(sender) }
        else if sender === crop { owner.toggleScreenAutoCrop(sender) }
        else if sender === mute { owner.toggleMute(sender) }
        else if sender === floating { owner.toggleFloat(sender) }
        else if sender === passthrough { owner.toggleClickThrough(sender) }
        else if sender === operation { owner.toggleGameOperationMode(sender) }
        refresh()
    }
    @objc private func changeVolume() { owner?.volumeSlider.doubleValue = volume.doubleValue; owner?.volumeChanged(volume); refresh() }
    @objc private func startSource() {
        guard let owner else { return }
        if sourceKinds.selection == 1, owner.screenTargets.indices.contains(screenPicker.indexOfSelectedItem) { owner.startScreenCapture(target: owner.screenTargets[screenPicker.indexOfSelectedItem]) }
        refresh()
    }
    @objc private func startCaptureCard(_ sender: NSButton) {
        guard let owner, let id = captureButtons.first(where: { $0.value === sender })?.key else { return }
        guard let video = owner.allVideoDevices().first(where: { $0.uniqueID == id }) else {
            showLaunchError("采集卡已断开，请重新连接后再试。")
            refresh()
            return
        }
        let options = owner.collectFormats(video)
        guard !options.isEmpty else { showLaunchError("这张采集卡没有可用的视频格式。"); return }
        let preferred = options.firstIndex { $0.width == 3840 && abs($0.fps - 60) < 1 } ?? 0
        owner.startConfiguredDevice(id: id, formatIndex: preferred)
        refresh()
    }
    private func showLaunchError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法启动"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
    @objc private func refreshSources() {
        if sourceKinds.selection == 1 { owner?.reloadScreenTargets(userInitiated: true) }
        else { refreshDevices() }
        refresh()
    }
    @objc private func startGamePlugin(_ sender: NSButton) {
        guard let owner, let id = sender.identifier?.rawValue else { return }
        owner.gameInjectionController.startGame(pluginID: id)
        if !owner.gameInjectionController.isGameRunning && !owner.gameInjectionController.status.contains("已打开 App Store") {
            showLaunchError(owner.gameInjectionController.status)
        }
        refresh()
    }
    @objc private func toggleGameInterpolation() { owner?.gameInjectionController.toggleGameInterpolation(); refresh() }
    @objc private func recordComparisonMovie() { owner?.toggleComparisonRecording(); refresh() }
    @objc private func openComparisonMovies() { owner?.revealComparisonRecording() }
    @objc private func recordGameFrames() { owner?.gameInjectionController.recordGameFrames(); refresh() }
    @objc private func showPreview() { owner?.showPreview() }
    @objc private func fullscreen() { if owner?.hasSelectedSource == true { owner?.goFullscreen(self) } }
    @objc private func screenshot() { owner?.takeScreenshot(self) }
    @objc private func diagnostics() { owner?.exportDiagnostics(self) }
    @objc private func logs() { owner?.openDiagnosticLogs(self) }
    @objc private func retryRenderer() { owner?.retryMetal(self) }
    @objc private func quitApplication() { NSApp.terminate(nil) }
}
