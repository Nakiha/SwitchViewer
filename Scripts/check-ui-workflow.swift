import AppKit
import AVFoundation

/// In-process UI regression: exercises the real game fixture and capture-session
/// transitions without opening the user's game or requesting device permissions.
@main
struct WorkflowCheck {
    static let owner = AppDelegate()
    static var panel: PerformanceToolbar!
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1
        print("PASS: \(message)")
    }
    static func later(_ seconds: Double = 0.4, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    static var tabs: NSSegmentedControl {
        descendants(panel.contentView!).compactMap { $0 as? NSSegmentedControl }
            .first { $0.label(forSegment: 0) == (panel.workflow == .capture ? "采集处理" : (panel.workflow == .game ? "插帧处理" : "视频采集")) }!
    }
    static func select(_ index: Int) {
        tabs.selectedSegment = index
        tabs.sendAction(tabs.action!, to: tabs.target)
    }
    static func button(_ title: String) -> NSButton {
        let matches = descendants(panel.contentView!).compactMap { $0 as? NSButton }.filter { $0.title == title }
        return matches.first { !$0.isHiddenOrHasHiddenAncestor } ?? matches.first!
    }
    static func visible(_ title: String) -> Bool { !button(title).isHiddenOrHasHiddenAncestor }
    static var workflowTitle: NSTextField {
        descendants(panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "workflow-title" }!
    }
    static func checkToolsLayout() {
        let row = descendants(panel.contentView!).first { $0.identifier?.rawValue == "tools-actions" }!
        let buttons = descendants(row).compactMap { $0 as? NSButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
        let frames = buttons.map { $0.convert($0.bounds, to: panel.contentView!) }
        expect(frames.count >= 3 && frames.allSatisfy { abs($0.midY - frames[0].midY) < 2 }
            && zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX },
            "tools use a compact row of aligned, non-overlapping buttons")
    }
    static func popup(_ id: String, in view: NSView) -> NSPopUpButton {
        descendants(view).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == id }!
    }
    static func checkDeviceHotPlug() {
        var snapshot: [AVCaptureDevice] = []
        let view = ViewerSettingsView(owner: owner, discoverVideoDevices: { snapshot })
        let format = popup("capture-format", in: view)
        func launchers() -> [NSButton] {
            descendants(view).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue == "capture-launch" }
        }
        expect(launchers().isEmpty && !format.isEnabled, "empty capture list shows no launch buttons or formats")
        let rawDevices = AVCaptureDevice.devices(for: .video)
        let builtIn = rawDevices.filter { $0.deviceType == .builtInWideAngleCamera || $0.deviceType == .deskViewCamera || $0.isContinuityCamera }
        snapshot = builtIn
        view.refresh()
        expect(launchers().isEmpty, "built-in and continuity cameras are excluded from capture launchers")
        for d in rawDevices { print("DEVICE: \(d.localizedName); type=\(d.deviceType.rawValue); capture=\(AppDelegate.isCaptureInput(d))") }
        let available = owner.allVideoDevices()
        guard let first = available.first else {
            print("SKIP: hot-plug snapshots need one external video device; no capture is started")
            return
        }
        snapshot = builtIn + [first]
        NotificationCenter.default.post(name: AVCaptureDevice.wasConnectedNotification, object: first)
        expect(launchers().map(\.title) == [first.localizedName], "connection notification creates a named capture launch button")
        if format.numberOfItems > 1 { format.selectItem(at: 1) }
        let chosenFormat = format.titleOfSelectedItem
        if let second = available.dropFirst().first {
            snapshot = [second, first]
            NotificationCenter.default.post(name: AVCaptureDevice.wasConnectedNotification, object: second)
            expect(launchers().map(\.title) == [second.localizedName, first.localizedName], "each external device gets its own launch button")
            snapshot = [second]
            NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: first)
            expect(launchers().map(\.title) == [second.localizedName], "disconnect removes only that device's launch button")
        } else {
            view.refresh()
            expect(format.titleOfSelectedItem == chosenFormat, "unchanged devices preserve the chosen runtime format")
        }
        snapshot = []
        NotificationCenter.default.post(name: AVCaptureDevice.wasDisconnectedNotification, object: first)
        expect(launchers().isEmpty && format.itemTitles == ["没有可用格式"], "disconnect clears stale launch buttons and format options")
        snapshot = [first]
        view.refresh()
        expect(launchers().map(\.title) == [first.localizedName], "periodic refresh discovers a card if notification was missed")
        owner.sessionQueue.suspend()
        let start = launchers()[0]
        start.sendAction(start.action!, to: start.target)
        expect(owner.hasSelectedSource && owner.window.isVisible, "one capture launch click opens the preview window")
        expect(owner.devicePopup.selectedItem?.representedObject as? String == first.uniqueID,
            "capture launch button routes to the matching device")
        owner.hasSelectedSource = false
        owner.beginNewSourceGeneration(reason: "Cancel launch check before opening hardware")
        owner.sessionQueue.resume()
        owner.sessionQueue.sync { expect(!owner.session.isRunning, "launch check does not open the user's hardware stream") }
        owner.window.orderOut(nil)
        snapshot = []
        view.refresh()
        expect(launchers().isEmpty, "periodic refresh clears disconnected launch buttons")
    }
    static func checkCaptureReconfiguration() {
        guard let video = owner.allVideoDevices().first else { return }
        let options = owner.collectFormats(video)
        guard options.count > 1 else { return }
        // Hold the capture queue while exercising the real action, then cancel
        // its queued request before resuming. No hardware stream is opened.
        owner.sessionQueue.suspend()
        owner.currentVideoDevice = video
        owner.formatOptions = options
        owner.formatPopup.removeAllItems()
        owner.formatPopup.addItems(withTitles: options.map(\.label))
        owner.formatPopup.selectItem(at: 0)
        owner.hasSelectedSource = true
        let view = ViewerSettingsView(owner: owner, discoverVideoDevices: { [video] })
        view.selectPage(2)
        let format = popup("capture-format", in: view)
        format.selectItem(at: 1)
        let requested = format.titleOfSelectedItem
        let previousGeneration = owner.sessionGeneration
        format.sendAction(format.action!, to: format.target)
        expect(owner.formatPopup.titleOfSelectedItem == requested, "runtime format action selects the requested resolution and frame rate")
        expect(owner.sessionGeneration > previousGeneration && owner.hasSelectedSource, "runtime format action reconfigures without leaving capture workflow")
        expect(owner.currentVideoDevice?.uniqueID == video.uniqueID, "runtime format action retains the active device")
        owner.hasSelectedSource = false
        owner.beginNewSourceGeneration(reason: "Cancel simulated format change before opening hardware")
        owner.sessionQueue.resume()
        owner.sessionQueue.sync { expect(!owner.session.isRunning, "cancelled format request never opens a hardware stream") }
        owner.currentVideoDevice = nil
        owner.formatOptions = []
        owner.formatPopup.removeAllItems()
        owner.window.orderOut(nil)
    }
    static func checkMissingGame() {
        let missing = URL(fileURLWithPath: "/nonexistent/SwitchViewerWorkflowCheck/鸣潮.app")
        var urls: [URL] = []
        owner.gameInjectionController.startGame(pluginID: "wuthering-waves", appURL: missing) { urls.append($0); return true }
        expect(urls.count == 1 && urls[0].scheme == "macappstore" && urls[0].path.hasSuffix("id6450693428"), "missing Wuwa opens its native App Store page")
        expect(!owner.gameInjectionController.isGameRunning && owner.gameInjectionController.status.contains("安装完成后"), "missing game keeps selection workflow with installation guidance")
        urls.removeAll()
        owner.gameInjectionController.startGame(pluginID: "wuthering-waves", appURL: missing) { url in urls.append(url); return url.scheme == "https" }
        expect(urls.count == 2 && urls.last?.scheme == "https", "App Store failure falls back to the official web listing")
        owner.gameInjectionController.startGame(pluginID: "wuthering-waves", appURL: missing) { _ in false }
        expect(owner.gameInjectionController.status.contains("无法打开 App Store"), "failed store opening leaves manual installation guidance")
        owner.gameInjectionController.startGame(pluginID: "unknown-plugin") { urls.append($0); return true }
        expect(owner.gameInjectionController.status.contains("找不到该游戏插件"), "unknown game plugin never launches a target")
        urls.removeAll()
        owner.gameInjectionController.startGame(pluginID: "generic-metal") { urls.append($0); return true }
        expect(owner.gameInjectionController.status.contains("找不到该游戏插件")
            && !owner.gameInjectionController.isGameRunning && urls.isEmpty,
            "diagnostic generic plugin cannot launch a user-selected game")
        let view = ViewerSettingsView(owner: owner, discoverVideoDevices: { [] })
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        expect(!buttons.contains { $0.title == "选择其他 Mac 游戏" }
            && buttons.contains { $0.identifier?.rawValue == "wuthering-waves" },
            "game selection only exposes registered game plugins")
    }
    static func click(_ title: String) {
        let control = button(title)
        control.sendAction(control.action!, to: control.target)
    }
    static func checkAbout(_ completion: @escaping () -> Void) {
        let workflow = panel.workflow
        click("关于")
        later {
            expect(tabs.selectedSegment == -1, "about clears tab selection")
            expect(visible("Nakiha") && visible("github.com/Nakiha/SwitchViewer") && visible("MIT License"), "about exposes author, repository and license links")
            expect(panel.workflow == workflow, "about preserves the current session")
            expect(Bundle.main.url(forResource: "LICENSE", withExtension: "txt") != nil, "license text is bundled for offline reading")
            validateLayout()
            let about = descendants(panel.contentView!).compactMap { $0 as? ProjectAboutView }.first!
            let bottomInset = about.convert(about.bounds, to: panel.contentView!).minY
            expect((23...25).contains(bottomInset), "about fits content with 24-point bottom padding")
            click("关于")
            later {
                expect(panel.frame.height == 60 && panel.workflow == workflow, "repeated about click collapses without losing session")
                completion()
            }
        }
    }
    static func validateLayout() {
        panel.contentView!.layoutSubtreeIfNeeded()
        let bounds = panel.contentView!.bounds.insetBy(dx: -1, dy: -1)
        let visibleViews = descendants(panel.contentView!).filter {
            !$0.isHiddenOrHasHiddenAncestor && ($0 is NSButton || $0 is NSTextField || $0 is NSSegmentedControl)
        }
        expect(visibleViews.allSatisfy { bounds.contains($0.convert($0.bounds, to: panel.contentView!)) }, "visible controls fit inside panel")
        if let configuration = descendants(panel.contentView!).compactMap({ $0 as? ViewerSettingsView }).first,
           !configuration.isHiddenOrHasHiddenAncestor,
           let stack = configuration.subviews.first as? NSStackView {
            let bottomInset = stack.convert(stack.bounds, to: panel.contentView!).minY
            expect((23...25).contains(bottomInset), "active tab fits content with 24-point bottom padding (actual: \(bottomInset))")
        }
    }
    static func main() {
        let app = NSApplication.shared
        app.delegate = owner
        later(1) {
            panel = app.windows.compactMap { $0 as? PerformanceToolbar }.first!
            let choices = GlassChoiceControl(["延迟", "帧率"])
            expect((choices.arrangedSubviews.first as? NSSegmentedControl)?.selectedSegment == 0, "ordinary choices retain default selection")
            expect(panel.workflow == .selection && tabs.segmentCount == 2, "startup has only capture and game tabs")
            expect(tabs.selectedSegment == -1 && panel.frame.height == 60, "startup is collapsed")
            expect(visible("关于"), "about is available on the selection page")
            expect(workflowTitle.stringValue == "SwitchViewer", "selection toolbar shows the app name")
            let close = descendants(panel.contentView!).compactMap { $0 as? NSButton }.first { $0.toolTip == "收起工具栏" }!
            expect(!close.isBordered, "toolbar close icon has no glass bezel")
            if CommandLine.arguments.contains("--preview") { return }
            if CommandLine.arguments.contains("--preview-selection") { select(0); return }
            if CommandLine.arguments.contains("--preview-game") {
                select(1)
                owner.gameInjectionController.startFixture()
                return
            }
            if CommandLine.arguments.contains("--preview-about") { click("关于"); return }
            if CommandLine.arguments.contains("--preview-capture") { owner.markSourceSelected(); return }
            if CommandLine.arguments.contains("--preview-tools") {
                owner.currentVideoDevice = owner.allVideoDevices().first
                owner.markSourceSelected()
                later { panel.showTab(3) }
                return
            }
            if CommandLine.arguments.contains("--preview-monitor") {
                owner.frameInterpolationEnabled = !CommandLine.arguments.contains("--interpolation-off")
                owner.markSourceSelected()
                later {
                    panel.showTab(1)
                    let metrics = PerformanceMetrics(fps: 60, latency: 16.9, p95: 22, processing: 2, wait: 14.9,
                        sourceFPS: 60, detectedContentFPS: 30, drawableWait: 0.1, gpu: 0.7, compositor: 14)
                    panel.receive(metrics)
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in panel.receive(metrics) }
                }
                return
            }
            checkDeviceHotPlug()
            checkCaptureReconfiguration()
            checkMissingGame()
            checkAbout { captureSelection() }
        }
        app.run()
    }
    static func captureSelection() {
        select(0)
        later {
            expect(!visible("开始采集") && !visible("刷新来源"), "capture selection hides dropdown start and refresh actions")
            expect(!descendants(panel.contentView!).contains { $0.identifier?.rawValue == "capture-device" }, "capture selection removes the device dropdown")
            expect(!descendants(panel.contentView!).compactMap { $0 as? NSTextField }.contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == "未运行" }, "selection page has no idle status footer")
            let sourceChoices = descendants(panel.contentView!).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "采集卡" }!
            sourceChoices.selectedSegment = 1
            sourceChoices.sendAction(sourceChoices.action!, to: sourceChoices.target)
            expect(visible("开始采集") && visible("刷新来源"), "screen selection retains its picker and source actions")
            expect(owner.ownWindowNumbers().allSatisfy { $0 != CGWindowID.max }, "unshown windows do not produce invalid screen capture IDs")
            sourceChoices.selectedSegment = 0
            sourceChoices.sendAction(sourceChoices.action!, to: sourceChoices.target)
            expect(popup("capture-format", in: panel.contentView!).isHiddenOrHasHiddenAncestor, "initial selection page does not show resolution settings")
            validateLayout()
            select(0)
            later {
                expect(panel.frame.height == 60, "repeated tab collapses")
                select(1)
                later {
                    expect(visible("鸣潮"), "game picker has Wuwa")
                    expect(!descendants(panel.contentView!).contains { ($0 as? NSButton)?.title == "选择游戏…" }, "no generic game picker")
                    validateLayout()
                    owner.gameInjectionController.startFixture()
                    later(3) { gameRunning() }
                }
            }
        }
    }
    static func gameRunning() {
        expect(panel.workflow == .game && tabs.segmentCount == 4, "game launch enters shared runtime tabs")
        expect(visible("退出游戏") && visible("开启插帧"), "game runtime has stop and interpolation controls")
        expect(owner.gameInjectionController.canToggleGameInterpolation, "fixture confirms interpolation control")
        expect(!visible("关于"), "game runtime hides about")
        expect(workflowTitle.stringValue == "游戏插帧 · 插帧测试窗口", "game runtime moves the game name into the toolbar title")
        validateLayout()
        checkCompactMetricsLayout()
        let toggle = button("开启插帧")
        toggle.state = .off
        toggle.sendAction(toggle.action!, to: toggle.target)
        later(1) {
            expect(!owner.gameInjectionController.isGameInterpolationEnabled, "shared processing toggle pauses actual game interpolation")
            gamePanels()
        }
    }
    static func checkCompactMetricsLayout() {
        let content = panel.contentView!
        let label = descendants(content).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "compact-metrics" }!
        var frames: [NSRect] = []
        for (fps, latency) in [(9.0, 1.0), (999.0, 999.9), (60.0, 16.7)] {
            panel.receive(PerformanceMetrics(fps: fps, latency: latency, p95: latency,
                processing: 1, wait: 1))
            content.layoutSubtreeIfNeeded()
            let tabFrame = tabs.convert(tabs.bounds, to: content)
            expect(label.convert(label.bounds, to: content).maxX < tabFrame.minX,
                "compact metrics stay left of the runtime tabs")
            frames.append(tabFrame)
        }
        expect(frames.dropFirst().allSatisfy { abs($0.minX - frames[0].minX) < 0.5
            && abs($0.width - frames[0].width) < 0.5 },
            "changing metric digit counts does not move or resize tabs")
    }
    static func gamePanels() {
        select(1)
        later {
            expect(!visible("开启插帧"), "monitor hides processing controls")
            let graphModes = descendants(panel.contentView!).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "帧率" }!
            expect(graphModes.selectedSegment == 0 && graphModes.label(forSegment: 1) == "延迟", "monitor starts with frame rate before latency")
            graphModes.selectedSegment = 1
            graphModes.sendAction(graphModes.action!, to: graphModes.target)
            expect(descendants(panel.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "延迟 · 蓝色 P50 / 橙色 P95 · ms" }, "second graph segment selects latency data")
            validateLayout()
            select(2)
            later {
                expect(visible("开启插帧"), "game shortcuts reflect paused interpolation")
                validateLayout()
                let resume = button("开启插帧")
                resume.sendAction(resume.action!, to: resume.target)
                later(1) { gameTools() }
            }
        }
    }
    static func gameTools() {
        expect(owner.gameInjectionController.isGameInterpolationEnabled, "shortcut button resumes actual game interpolation")
        select(3)
        later {
            expect(visible("记录 30 秒") && !visible("保存截图"), "tools show game actions")
            checkToolsLayout()
            validateLayout()
            // Closing a tab while the fixture runs must not return to setup.
            select(3)
            later {
                expect(panel.workflow == .game && panel.frame.height == 60, "runtime can collapse without losing session")
                owner.gameInjectionController.stopGame()
                later(1) {
                    expect(panel.workflow == .selection && tabs.selectedSegment == 1, "game exit returns to game picker")
                    expect(visible("关于"), "game exit restores about")
                    expect(workflowTitle.stringValue == "SwitchViewer", "game exit restores the app title")
                    captureRunning()
                }
            }
        }
    }
    static func captureRunning() {
        select(0)
        owner.markSourceSelected()
        later {
            expect(panel.workflow == .capture && tabs.segmentCount == 4, "capture uses the same runtime tabs")
            expect(tabs.label(forSegment: 0) == "采集处理", "capture runtime names processing tab for capture")
            expect(!popup("capture-format", in: panel.contentView!).isHiddenOrHasHiddenAncestor, "capture runtime shows resolution and frame rate settings")
            expect(NSApp.activationPolicy() == .regular, "capture preview appears in Dock")
            owner.window.orderOut(nil)
            _ = owner.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
            expect(owner.window.isVisible, "Dock reopen restores preview even with toolbar visible")
            expect(!visible("关于"), "capture runtime hides about")
            expect(owner.window.isVisible, "capture opens preview window")
            expect(visible("停止采集") && !visible("显示画面") && !visible("全屏覆盖游戏画面"), "capture-card processing omits screen operation controls")
            expect(workflowTitle.stringValue == "视频采集 · \(owner.selectedSourceName)", "capture source information moves into the toolbar title")
            expect(descendants(panel.contentView!).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor
                && $0.stringValue == workflowTitle.stringValue }.count == 1, "processing panel does not repeat the source title")
            validateLayout()
            let sections = ["音视频配置", "插帧配置"].map { name in
                descendants(panel.contentView!).first { $0.identifier?.rawValue == name }!
            }
            let columns = sections.map { $0.convert($0.bounds, to: panel.contentView!) }
            expect(columns[0].maxX < columns[1].minX
                && abs(columns[1].maxX - panel.contentView!.bounds.maxX + 20) < 2,
                "capture card uses two columns across the panel width")
            let rightControls = descendants(sections[1]).compactMap { $0 as? NSButton }
            expect(rightControls.contains { $0.title == "开启插帧" }
                && rightControls.contains { $0.title == "降低原帧清晰度以匹配插帧" },
                "capture interpolation controls stay together in the right column")
            expect(columns[1].height < columns[0].height - 40,
                "short interpolation column keeps controls compact at the top")
            panel.showTab(1)
            let graphModes = descendants(panel.contentView!).compactMap { $0 as? NSSegmentedControl }.first { $0.label(forSegment: 0) == "帧率" }!
            graphModes.selectedSegment = 0
            graphModes.sendAction(graphModes.action!, to: graphModes.target)
            let detected = descendants(panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "detected-content-fps" }!
            let notice = descendants(panel.contentView!).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "interpolation-disabled-notice" }!
            expect(!notice.isHiddenOrHasHiddenAncestor && detected.isHiddenOrHasHiddenAncestor,
                "disabled interpolation shows a clear notice and hides detected frame rate")
            owner.frameInterpolationEnabled = true
            panel.refreshConfiguration()
            expect(notice.isHiddenOrHasHiddenAncestor && !detected.isHiddenOrHasHiddenAncestor,
                "enabled interpolation shows detected frame rate and removes the disabled notice")
            let metrics = PerformanceMetrics(fps: 60, latency: 16.9, p95: 22, processing: 2, wait: 14.9,
                sourceFPS: 60, detectedContentFPS: 30)
            owner.gameInjectionController.receiveScreenMetrics(metrics)
            expect(detected.stringValue == "30 fps", "monitor shows detected 30 fps content independently from 60 fps input")
            expect(descendants(panel.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("绿色检测") },
                "frame rate legend explains the green detected-content series")
            validateLayout()
            var missingDetection = metrics
            missingDetection.detectedContentFPS = nil
            panel.receive(missingDetection)
            expect(detected.stringValue == "— fps", "unknown detected cadence stays unknown instead of copying input FPS")
            var invalidDetection = metrics
            invalidDetection.detectedContentFPS = .nan
            panel.receive(invalidDetection)
            expect(detected.stringValue == "— fps", "invalid detected cadence cannot corrupt the metric or graph")
            panel.receive(metrics)
            panel.resetMetrics()
            expect(detected.stringValue == "— fps", "new sessions clear the previous detected frame rate")
            owner.frameInterpolationEnabled = false
            panel.refreshConfiguration()
            expect(detected.isHiddenOrHasHiddenAncestor
                && !descendants(panel.contentView!).compactMap { $0 as? NSTextField }.contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("绿色检测") },
                "disabled interpolation hides both detected value and green graph legend")
            panel.showTab(0)
            owner.window.standardWindowButton(.zoomButton)!.performClick(nil)
            later(1.5) {
                expect(owner.window.styleMask.contains(.fullScreen), "green window button enters full screen")
                owner.window.toggleFullScreen(nil)
                later(1.5) {
                    expect(!owner.window.styleMask.contains(.fullScreen), "preview exits full screen")
                    captureShortcuts()
                }
            }
        }
    }
    static func captureShortcuts() {
        select(2)
        later {
            expect(!visible("关闭插帧"), "capture shortcuts hide game control")
            select(3)
            later {
                expect(visible("保存截图") && !visible("记录 30 秒"), "tools show capture actions")
                checkToolsLayout()
                validateLayout()
                owner.stopCapture()
                later {
                    expect(panel.workflow == .selection && tabs.selectedSegment == 0, "capture stop returns to capture picker")
                    expect(visible("关于"), "capture stop restores about")
                    expect(!owner.window.isVisible, "capture stop hides preview")
                    expect(NSApp.activationPolicy() == .accessory, "stopping capture removes Dock entry")
                    validateLayout()
                    captureDisconnected()
                }
            }
        }
    }
    static func captureDisconnected() {
        owner.videoSource = .screen
        owner.markSourceSelected()
        later {
            expect(panel.workflow == .capture, "screen session enters runtime")
            expect(visible("显示画面") && visible("全屏覆盖游戏画面"), "screen capture retains its operation controls")
            expect(popup("capture-format", in: panel.contentView!).isHiddenOrHasHiddenAncestor, "screen capture hides capture-card formats")
            owner.returnToSourceSelection(message: "Simulated source disconnect")
            later {
                expect(panel.workflow == .selection && tabs.selectedSegment == 0, "lost screen source returns to capture picker")
                expect(!owner.window.isVisible, "lost source hides preview")
                expect(NSApp.activationPolicy() == .accessory, "lost source removes Dock entry")
                print("UI workflow: \(checks) checks passed")
                owner.gameInjectionController.shutdown()
                exit(0)
            }
        }
    }

}
