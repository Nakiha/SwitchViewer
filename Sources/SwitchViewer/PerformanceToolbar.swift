import AppKit
import QuartzCore

enum ViewerWorkflow: Equatable {
    case selection, capture, game
    var isRunning: Bool { self != .selection }
}

struct PerformanceMetrics {
    let fps: Double
    let latency: Double
    let p95: Double
    let processing: Double?
    let wait: Double
    var originalAge: Double? = nil
    var sourceFPS: Double? = nil
    var detectedContentFPS: Double? = nil
    var drawableWait: Double? = nil
    var gpu: Double? = nil
    var compositor: Double? = nil
}

/// One horizontal control bar; configuration and telemetry expand in place.
final class PerformanceToolbar: NSPanel {
    private let brand = NSTextField(labelWithString: "SwitchViewer")
    private var metricValues: [NSTextField] = []
    private let compactMetrics = NSTextField(labelWithString: "— fps · — ms")
    private let chart = PerformanceChart(frame: .zero)
    private let caption = NSTextField(labelWithString: "帧率 · 蓝色显示 / 橙色原始 / 绿色检测 · fps")
    private let tabs = GlassChoiceControl(["视频采集", "游戏插帧"], symbols: ["video", "gamecontroller"])
    private lazy var endSession = NSButton(title: "结束运行", target: self, action: #selector(stopSession))
    private weak var owner: AppDelegate?
    private(set) var workflow: ViewerWorkflow = .selection
    private var lastSelectionTab = 0
    private var panelWidth: CGFloat { workflow.isRunning ? 840 : 620 }
    private var isMonitoring: Bool { workflow.isRunning && activeTab == 1 }
    private let bodyHost = NSView()
    private let statistics = NSStackView()
    private let interpolationNotice = NSTextField(labelWithString: "插帧未开启 · 当前显示原始画面")
    private var detectedFPSCell: NSStackView!
    private var displayedFPSLabel: NSTextField!
    private let aboutView = ProjectAboutView()
    private var aboutButton: NSButton!
    private var showingAbout = false
    private var bodyHeight: NSLayoutConstraint!
    private var configuration: ViewerSettingsView?
    private var configurationHeight: CGFloat = 200
    private var activeTab = -1
    private var selectingTab = false
    private var transitionRevision = 0
    private var lastSample = Date.distantPast
    private var freshnessTimer: Timer?
    override var canBecomeKey: Bool { showingAbout || (activeTab >= 0 && !isMonitoring) }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "SwitchViewer 悬浮工具栏"
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSView()
        content.focusRingType = .none
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // The panel is a reading surface. Keep interaction highlights on
            // individual controls instead of brightening the entire background.
            glass.style = .regular
            glass.cornerRadius = 22
            // The window's root surface must share the glass silhouette,
            // including while it is key and while its frame is animated.
            glass.focusRingType = .none
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 22
            glass.layer?.masksToBounds = true
            if #available(macOS 27.0, *) { glass.effectIsInteractive = false }
            glass.contentView = content
            contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.addSubview(content)
            content.frame = material.bounds
            content.autoresizingMask = [.width, .height]
            contentView = material
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "SwitchViewer")!)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        brand.font = .systemFont(ofSize: 13, weight: .semibold)
        brand.identifier = NSUserInterfaceItemIdentifier("workflow-title")
        brand.lineBreakMode = .byTruncatingTail
        brand.maximumNumberOfLines = 1
        brand.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        brand.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        tabs.allowsEmptySelection = true
        tabs.selection = -1
        tabs.onChange = { [weak self] index in self?.showTab(index) }
        compactMetrics.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        compactMetrics.textColor = .secondaryLabelColor
        compactMetrics.toolTip = "实际显示帧率 · 取帧到显示 P50"
        compactMetrics.identifier = NSUserInterfaceItemIdentifier("compact-metrics")
        compactMetrics.widthAnchor.constraint(equalToConstant: 132).isActive = true
        compactMetrics.lineBreakMode = .byTruncatingTail
        compactMetrics.maximumNumberOfLines = 1
        let about = button("info.circle", label: "关于 SwitchViewer", action: #selector(toggleAbout))
        aboutButton = about
        about.title = "关于"
        about.imagePosition = .imageLeading
        about.setAccessibilityLabel("关于 SwitchViewer")
        let hide = button("xmark", label: "收起工具栏", action: #selector(hideToolbar))
        hide.bezelStyle = .rounded
        hide.isBordered = false
        hide.widthAnchor.constraint(equalToConstant: 28).isActive = true
        endSession.bezelStyle = .rounded
        if #available(macOS 26.0, *) { endSession.bezelStyle = .glass }
        endSession.isHidden = true
        compactMetrics.isHidden = true
        let row = NSStackView(views: [icon, brand, NSView(), compactMetrics, tabs, NSView(), endSession, about, hide])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)
        bodyHost.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.focusRingType = .none
        content.addSubview(bodyHost)
        bodyHost.isHidden = true
        bodyHeight = bodyHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            row.heightAnchor.constraint(equalToConstant: 28),
            bodyHost.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 14),
            bodyHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bodyHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), bodyHeight
        ])
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        let metricTitles = ["原始帧率", "插帧后帧率", "总时延", "就绪 → 显示",
                            "插帧处理", "绘制等待", "GPU 绘制", "GPU → 显示", "检测帧率"]
        let cells = metricTitles.enumerated().map { index, title -> NSStackView in
            let isFPS = index < 2 || index == 8
            let label = NSTextField(labelWithString: title)
            if index == 1 { displayedFPSLabel = label }
            label.font = .systemFont(ofSize: isFPS || index == 2 ? 11 : 10)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: isFPS ? "— fps" : "— ms")
            value.font = .monospacedDigitSystemFont(ofSize: index == 2 ? 24 : (isFPS ? 20 : 17), weight: .medium)
            value.setAccessibilityLabel(title)
            value.toolTip = index < 2 ? (index == 0 ? "游戏按原帧提交计数；屏幕 / 采集卡按输入回调计数，除以同一统计窗口的时长。" : "实际确认上屏的帧率，含原帧和生成帧") : "该阶段的 P50；不同阶段的分位数不能直接相加"
            if index == 5 { value.toolTip = "等待获取用于屏幕绘制的缓冲区所花的时间（P50）。" }
            if index == 6 { value.toolTip = "GPU 执行画面绘制所花的时间（P50），不包含插帧计算。" }
            if index == 8 {
                value.identifier = NSUserInterfaceItemIdentifier("detected-content-fps")
                value.textColor = .systemGreen
                value.toolTip = "开启插帧时按画面内容估算更新率，采集卡优先识别重复画面节奏；静止画面可显示 0。预热、格式不支持或游戏内插帧模式下显示 —。这不是游戏内部计时帧率。"
            }
            metricValues.append(value)
            let cell = NSStackView(views: [label, value])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 4
            return cell
        }
        let fpsRow = NSStackView(views: [cells[1], cells[0], cells[8], NSView()])
        detectedFPSCell = cells[8]
        cells[1].widthAnchor.constraint(equalToConstant: 140).isActive = true
        cells[0].widthAnchor.constraint(equalTo: cells[1].widthAnchor).isActive = true
        cells[8].widthAnchor.constraint(equalTo: cells[1].widthAnchor).isActive = true
        fpsRow.spacing = 32
        let stages = NSStackView(views: [cells[4], cells[5], cells[6], cells[7], cells[3]])
        stages.spacing = 18
        stages.alignment = .bottom
        let latencyRow = NSStackView(views: [cells[2], stages, NSView()])
        latencyRow.spacing = 32
        latencyRow.alignment = .top
        let grid = NSStackView(views: [fpsRow, latencyRow])
        // Cross-row constraints require both cells to have a common ancestor.
        cells[2].widthAnchor.constraint(equalTo: cells[1].widthAnchor).isActive = true
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 16
        fpsRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        latencyRow.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        let modes = GlassChoiceControl(["帧率", "延迟", "处理"])
        modes.onChange = { [weak self] mode in self?.changeChart(mode) }
        let graphHeader = NSStackView(views: [caption, NSView(), modes])
        statistics.orientation = .vertical
        statistics.alignment = .leading
        statistics.spacing = 10
        interpolationNotice.identifier = NSUserInterfaceItemIdentifier("interpolation-disabled-notice")
        interpolationNotice.font = .systemFont(ofSize: 13, weight: .semibold)
        interpolationNotice.textColor = .systemOrange
        interpolationNotice.isHidden = true
        for view in [interpolationNotice, grid, graphHeader, chart] { statistics.addArrangedSubview(view) }
        statistics.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.addSubview(statistics)
        NSLayoutConstraint.activate([
            statistics.topAnchor.constraint(equalTo: bodyHost.topAnchor),
            statistics.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
            statistics.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
            graphHeader.widthAnchor.constraint(equalTo: statistics.widthAnchor),
            grid.widthAnchor.constraint(equalTo: statistics.widthAnchor),
            chart.widthAnchor.constraint(equalTo: statistics.widthAnchor),
            chart.heightAnchor.constraint(equalToConstant: 110)
        ])
        statistics.isHidden = true
        aboutView.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.addSubview(aboutView)
        NSLayoutConstraint.activate([
            aboutView.topAnchor.constraint(equalTo: bodyHost.topAnchor),
            aboutView.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
            aboutView.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor)
        ])
        aboutView.isHidden = true
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        setFrameOrigin(NSPoint(x: visible.midX - 380, y: visible.maxY - 90))
        setFrameAutosaveName("SwitchViewer.ControlBar")
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            refreshHeader()
            refreshInterpolationState()
            guard Date().timeIntervalSince(lastSample) > 5 else { return }
            clearMetricValues()
            compactMetrics.stringValue = "— fps · — ms"
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func installConfiguration(_ view: ViewerSettingsView, owner: AppDelegate) {
        self.owner = owner
        configuration = view
        view.translatesAutoresizingMaskIntoConstraints = false
        bodyHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: bodyHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: bodyHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: bodyHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bodyHost.bottomAnchor)
        ])
        view.isHidden = true
        view.onHeightChanged = { [weak self] height in
            guard let self else { return }
            guard configurationHeight != height else { return }
            configurationHeight = height
            if !selectingTab && activeTab >= 0 && !isMonitoring { resizeBody(height) }
        }
    }
    private func refreshHeader() {
        guard let owner else { return }
        let text: String
        if owner.gameInjectionController.isGameRunning {
            text = "游戏插帧 · \(owner.gameInjectionController.runningGameName ?? "游戏")"
        } else if owner.hasSelectedSource {
            text = "视频采集 · \(owner.selectedSourceName)"
        } else {
            text = "SwitchViewer"
        }
        brand.stringValue = text
        brand.toolTip = text
    }
    private func refreshInterpolationState() {
        guard let owner else { return }
        let enabled = workflow == .game ? owner.gameInjectionController.isGameInterpolationEnabled : owner.frameInterpolationEnabled
        let showDetection = enabled && workflow == .capture
        if showDetection != chart.showsDetection { metricValues[8].stringValue = "— fps" }
        let noticeWasHidden = interpolationNotice.isHidden
        interpolationNotice.isHidden = enabled || !workflow.isRunning
        detectedFPSCell.isHidden = !showDetection
        displayedFPSLabel.stringValue = enabled ? "插帧后帧率" : "显示帧率"
        chart.showsDetection = showDetection
        updateChartCaption()
        chart.needsDisplay = true
        if isMonitoring && noticeWasHidden != interpolationNotice.isHidden {
            resizeBody(ceil(statistics.fittingSize.height) + 8)
        }
    }
    func refreshConfiguration() { refreshHeader(); refreshInterpolationState(); configuration?.refresh() }

    func synchronizeWorkflow() {
        guard let owner else { return }
        let next: ViewerWorkflow = owner.gameInjectionController.isGameRunning ? .game
            : (owner.hasSelectedSource ? .capture : .selection)
        refreshHeader()
        guard next != workflow else { return }
        workflow = next
        refreshInterpolationState()
        tabs.setChoices(next.isRunning ? [next == .capture ? "采集处理" : "插帧处理", "监控", "快捷键", "工具"] : ["视频采集", "游戏插帧"],
            symbols: next.isRunning ? ["slider.horizontal.3", "chart.xyaxis.line", "keyboard", "wrench.and.screwdriver"] : ["video", "gamecontroller"])
        endSession.isHidden = !next.isRunning
        endSession.title = next == .game ? "退出游戏" : "停止采集"
        compactMetrics.isHidden = !next.isRunning
        aboutButton.isHidden = next.isRunning
        resetMetrics()
        showTab(next.isRunning ? 0 : lastSelectionTab)
    }
    @objc private func stopSession() {
        if workflow == .game { owner?.gameInjectionController.stopGame() }
        else if workflow == .capture { owner?.stopCapture() }
    }
    func show() {
        // Saved positions can become unreachable after unplugging a display.
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        if let visible {
            let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            let y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        if isMiniaturized { deminiaturize(nil) }
        orderFrontRegardless()
        if canBecomeKey { makeKey() }
    }
    func showTab(_ index: Int) {
        guard index >= -1 && index < (workflow.isRunning ? 4 : 2) else { return }
        refreshHeader()
        showingAbout = false
        aboutView.isHidden = true
        let previousTab = activeTab
        activeTab = index
        refreshInterpolationState()
        tabs.selection = index
        if !workflow.isRunning && index >= 0 { lastSelectionTab = index }
        if index >= 0 {
            bodyHost.isHidden = false
            statistics.isHidden = !isMonitoring
            configuration?.isHidden = isMonitoring
            if previousTab != index { bodyHost.alphaValue = 0 }
        }
        selectingTab = true
        if index >= 0 && !isMonitoring {
            // Configuration pages: capture picker, game picker, processing,
            // shortcuts, tools. Monitoring lives in the toolbar itself.
            let page = workflow.isRunning ? (index == 0 ? 2 : index + 1) : index
            configuration?.selectPage(page)
            configuration?.activate()
        }
        selectingTab = false
        resizeBody(index < 0 ? 0 : (isMonitoring ? ceil(statistics.fittingSize.height) + 8 : configurationHeight))
        if canBecomeKey { makeKeyAndOrderFront(nil) }
    }
    @objc private func toggleAbout() {
        if showingAbout { showTab(-1); return }
        showingAbout = true
        activeTab = -1
        tabs.selection = -1
        statistics.isHidden = true
        configuration?.isHidden = true
        aboutView.isHidden = false
        bodyHost.isHidden = false
        bodyHost.alphaValue = 0
        resizeBody(ceil(aboutView.fittingSize.height) + 8)
        makeKeyAndOrderFront(nil)
    }
    private func resizeBody(_ height: CGFloat) {
        transitionRevision += 1
        let revision = transitionRevision
        if height > 0 { bodyHeight.constant = height }
        let size = height > 0 ? 74 + height : 60
        let top = frame.maxY
        var origin = NSPoint(x: frame.minX, y: top - size)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - panelWidth))
            origin.y = max(visible.minY, origin.y)
        }
        let target = NSRect(origin: origin, size: NSSize(width: panelWidth, height: size))
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !isVisible ? 0 : 0.28
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
            animator().setFrame(target, display: true)
            bodyHost.animator().alphaValue = height > 0 ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, transitionRevision == revision else { return }
            if height == 0 {
                bodyHost.isHidden = true
                bodyHeight.constant = 0
            }
        }
    }
    private func button(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .rounded
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }
        button.toolTip = label
        return button
    }
    func resetMetrics() {
        lastSample = .distantPast
        clearMetricValues()
        compactMetrics.stringValue = "— fps · — ms"
        chart.samples.removeAll()
        chart.needsDisplay = true
    }
    private func clearMetricValues() {
        for (index, value) in metricValues.enumerated() { value.stringValue = index < 2 || index == 8 ? "— fps" : "— ms" }
    }
    func receive(_ m: PerformanceMetrics) {
        guard ([m.fps, m.latency, m.p95, m.wait] + (m.processing.map { [$0] } ?? [])).allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        lastSample = Date()
        refreshInterpolationState()
        compactMetrics.stringValue = String(format: "%.0f fps · %.1f ms", m.fps, m.latency)
        let values: [Double?] = [m.sourceFPS, m.fps, m.latency, m.wait, m.processing, m.drawableWait, m.gpu, m.compositor, m.detectedContentFPS]
        for (index, value) in values.enumerated() {
            let isFPS = index < 2 || index == 8
            if let value, value.isFinite, value >= 0 {
                metricValues[index].stringValue = String(format: isFPS ? "%.0f fps" : "%.1f ms", value)
            } else { metricValues[index].stringValue = isFPS ? "— fps" : "— ms" }
        }
        metricValues[2].toolTip = String(format: "取帧到显示参考年龄：P50 %.1f ms，P95 %.1f ms；不含游戏输入和逻辑延迟", m.latency, m.p95)
        chart.samples.append((Date(), m))
        chart.samples.removeAll { Date().timeIntervalSince($0.0) > 60 }
        if chart.samples.count > 120 { chart.samples.removeFirst(chart.samples.count - 120) }
        chart.needsDisplay = true
    }
    private func changeChart(_ mode: Int) {
        chart.mode = mode
        updateChartCaption()
        chart.needsDisplay = true
    }
    private func updateChartCaption() {
        caption.stringValue = [chart.showsDetection ? "帧率 · 蓝色显示 / 橙色原始 / 绿色检测 · fps" : "帧率 · 蓝色显示 / 橙色原始 · fps", "延迟 · 蓝色 P50 / 橙色 P95 · ms", "处理 · 蓝色插帧 / 橙色显示等待 · ms"][chart.mode]
    }
    @objc private func hideToolbar() { orderOut(nil) }
    deinit { freshnessTimer?.invalidate() }
}

private final class PerformanceChart: NSView {
    var samples: [(Date, PerformanceMetrics)] = []
    var mode = 0
    var showsDetection = false
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let area = bounds.insetBy(dx: 1, dy: 12)
        let series: [((PerformanceMetrics) -> Double?, NSColor)]
        switch mode {
        case 0: series = [({ $0.fps }, .systemBlue), ({ $0.sourceFPS }, .systemOrange)]
            + (showsDetection ? [({ $0.detectedContentFPS }, .systemGreen)] : [])
        case 2: series = [({ $0.processing }, .systemBlue), ({ $0.wait }, .systemOrange)]
        default: series = [({ $0.latency }, .systemBlue), ({ $0.p95 }, .systemOrange)]
        }
        let maximum = samples.flatMap { sample in series.compactMap { $0.0(sample.1) }.filter { $0.isFinite && $0 >= 0 } }.max() ?? 40
        let ceiling = max(40, ceil(maximum / 20) * 20)
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        for fraction in [0.0, 0.5, 1.0] {
            let y = area.minY + area.height * fraction
            let path = NSBezierPath(); path.move(to: NSPoint(x: area.minX, y: y)); path.line(to: NSPoint(x: area.maxX, y: y)); path.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        (String(format: mode == 0 ? "%.0f fps" : "%.0f ms", ceiling) as NSString).draw(at: NSPoint(x: area.minX, y: area.maxY + 1), withAttributes: attrs)
        ("−60 s" as NSString).draw(at: NSPoint(x: area.minX, y: 0), withAttributes: attrs)
        ("现在" as NSString).draw(at: NSPoint(x: area.maxX - 24, y: 0), withAttributes: attrs)
        guard samples.count >= 2, let end = samples.last?.0 else { return }
        for (key, color) in series {
            color.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1.8
            var started = false
            var lastDate: Date?
            for (time, value) in samples {
                guard let measurement = key(value), measurement.isFinite, measurement >= 0 else { started = false; continue }
                let point = NSPoint(x: area.maxX - end.timeIntervalSince(time) / 60 * area.width,
                                    y: area.minY + min(1, measurement / ceiling) * area.height)
                if !started || (lastDate.map { time.timeIntervalSince($0) > 5 } ?? false) { path.move(to: point); started = true }
                else { path.line(to: point) }
                lastDate = time
            }
            path.stroke()
        }
    }
}
