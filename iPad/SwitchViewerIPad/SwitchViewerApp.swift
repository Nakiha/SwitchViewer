import SwiftUI

@main
struct SwitchViewerIPadApp: App {
    @StateObject private var controller = CaptureController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ViewerScreen(controller: controller)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in controller.setActive(phase == .active) }
        }
    }
}

private struct ViewerScreen: View {
    @ObservedObject var controller: CaptureController
    @State private var settings = false
    @State private var controlsVisible = true
    @State private var eyeVisible = true
    @State private var eyeHideTask: Task<Void, Never>?

    private func scheduleEyeHide() {
        eyeHideTask?.cancel()
        guard !controlsVisible else { return }
        eyeHideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard !controlsVisible else { return }
            withAnimation(.easeOut(duration: 0.2)) { eyeVisible = false }
        }
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(version)（\(build)）"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalPreview(controller: controller).ignoresSafeArea()
            if !controller.running {
                VStack(spacing: 20) {
                    Image(systemName: "gamecontroller").font(.system(size: 64)).foregroundStyle(.cyan)
                    Text("SwitchViewer").font(.largeTitle.bold())
                    Text(controller.status).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text("Switch 底座 → HDMI 采集卡 → iPad USB-C")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button("开始采集", systemImage: "play.fill") { controller.startCapture() }
                            .buttonStyle(.borderedProminent)
                        Button("查看演示", systemImage: "sparkles") { controller.startDemo() }
                            .buttonStyle(.bordered)
                    }
                }.padding(32)
            }
            if controlsVisible {
                VStack {
                    HStack {
                        Label("SwitchViewer", systemImage: "gamecontroller.fill").font(.headline)
                        Spacer()
                        if controller.running {
                            CapturePerformanceBadge(metrics: controller.metrics)
                                .font(.callout.monospacedDigit())
                            Button("停止", systemImage: "stop.fill") { controller.stop() }
                        }
                        Button("设置", systemImage: "slider.horizontal.3") { settings = true }
                            .labelStyle(.iconOnly)
                        Button("隐藏控制", systemImage: "eye.slash") { controlsVisible = false }
                            .labelStyle(.iconOnly)
                    }
                    .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    Spacer()
                    if controller.running {
                        HStack {
                            Text(controller.status).lineLimit(1)
                            Spacer()
                            CaptureInterpolationStatus(metrics: controller.metrics).lineLimit(1)
                        }.font(.caption).padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }.padding(20)
            } else if eyeVisible {
                VStack {
                    HStack {
                        Spacer()
                        Button("显示控制", systemImage: "eye") { controlsVisible = true }
                            .labelStyle(.iconOnly).padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }.padding(20)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !controlsVisible else { return }
                eyeHideTask?.cancel()
                eyeVisible = true
            }
            .onEnded { _ in
                guard !controlsVisible else { return }
                scheduleEyeHide()
            })
        .onChange(of: controlsVisible) { _, _ in
            eyeVisible = true
            scheduleEyeHide()
        }
        .onDisappear { eyeHideTask?.cancel() }
        .sheet(isPresented: $settings) {
            NavigationStack {
                Form {
                    Section {
                        if controller.devices.isEmpty {
                            Text("未发现 USB 视频设备").foregroundStyle(.secondary)
                        } else {
                            Picker("设备", selection: $controller.selectedDeviceID) {
                                ForEach(controller.devices) { Text($0.name).tag($0.id) }
                            }.onChange(of: controller.selectedDeviceID) { _, _ in controller.selectionChanged() }
                            Picker("画面格式", selection: $controller.selectedFormatID) {
                                ForEach(controller.formats) { Text($0.label).tag($0.id) }
                            }.pickerStyle(.navigationLink)
                                .onChange(of: controller.selectedFormatID) { _, _ in controller.formatChanged() }
                        }
                        Button("刷新设备", systemImage: "arrow.clockwise") { controller.refreshDevices() }
                        Button("开始采集", systemImage: "play.fill") { controller.startCapture(); settings = false }
                    } header: { Text("采集卡") } footer: {
                        Text("显示采集卡实际提供的采集模式。4K 输入或 HDMI 直通不等于支持 USB 4K 采集。")
                    }
                    Section {
                        Toggle("Apple 低延迟插帧", isOn: Binding(get: { controller.interpolationEnabled },
                                                                set: controller.setInterpolation))
                            .disabled(!FramePipeline.supportsInterpolation)
                        CaptureInterpolationStatus(metrics: controller.metrics).font(.caption).foregroundStyle(.secondary)
                    } header: { Text("插帧") } footer: {
                        Text(FramePipeline.supportsInterpolation
                             ? "按画面变化生成中间帧。插帧需要缓冲，会增加延迟；关闭后优先显示原始画面。4K 模式保留原始帧清晰度，中间帧以 1080p 生成后放大显示。"
                             : "当前环境不支持 Apple 插帧。模拟器可测试界面和演示，插帧需要在支持的 iPad 真机上验证。")
                    }
                    Section {
                        Toggle("播放采集卡声音", isOn: Binding(get: { controller.soundEnabled }, set: controller.setSound))
                            .disabled(!controller.running || controller.demo)
                        Text(controller.soundStatus).font(.caption).foregroundStyle(.secondary)
                    } header: { Text("声音") } footer: {
                        Text("使用 USB 音频输入，经 iPad 扬声器或耳机播放。首版声音直接播放，插帧开启时可能与缓冲后的画面有时间差。")
                    }
                    Section("播放状态") {
                        CapturePlaybackStatistics(metrics: controller.metrics)
                        LabeledContent("App 版本", value: versionLabel)
                        Text("时间从 App 收到画面起计算，不包含 Switch 和采集卡自身的延迟。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("演示") {
                        Button("播放 30 帧演示画面", systemImage: "sparkles") { controller.startDemo(); settings = false }
                    }
                }
                .navigationTitle("播放设置")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
            }
        }
    }
}

// Keep periodic telemetry invalidation inside these small views. The settings
// form and its format chooser observe only capture configuration changes.
private struct CapturePerformanceBadge: View {
    @ObservedObject var metrics: CaptureMetrics
    var body: some View {
        Text("采集 \(metrics.sourceFPS, specifier: "%.0f") · 显示 \(metrics.displayedFPS, specifier: "%.0f") 帧")
    }
}

private struct CaptureInterpolationStatus: View {
    @ObservedObject var metrics: CaptureMetrics
    var body: some View { Text(metrics.interpolationStatus) }
}

private struct CapturePlaybackStatistics: View {
    @ObservedObject var metrics: CaptureMetrics
    var body: some View {
        Group {
            LabeledContent("实际采集分辨率", value: metrics.actualResolution)
            LabeledContent("采集帧率", value: String(format: "%.1f", metrics.sourceFPS))
            LabeledContent("画面更新", value: metrics.contentFPS.map { String(format: "%.1f 帧", $0) } ?? "检测中")
            LabeledContent("实际呈现", value: String(format: "%.1f 帧", metrics.displayedFPS))
            LabeledContent("插值呈现", value: String(format: "%.1f 帧", metrics.midpointFPS))
            LabeledContent("App 内平均呈现时间", value: String(format: "%.1f ms", metrics.latency))
        }
    }
}
