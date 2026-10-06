# SwitchViewer

[![Build and test](https://github.com/Nakiha/SwitchViewer/actions/workflows/ci.yml/badge.svg)](https://github.com/Nakiha/SwitchViewer/actions/workflows/ci.yml)

面向 macOS 和 iPad 的游戏采集预览工具：通过 UVC HDMI 采集卡查看 Switch 等设备的画面，提供音频监听、可选 Apple 插帧与性能监测。macOS 版还提供屏幕捕获与实验性 Metal 游戏内插帧。

项目处于早期开发阶段。采集预览、屏幕捕获和游戏内插帧使用不同链路，性能与兼容性不能互相替代。项目与 Nintendo、Apple 或游戏厂商无关联。

## 环境要求

- 当前源码使用 Xcode 27 SDK 中的接口，建议使用 **Xcode 27 或更新版本**，并将其设置为命令行开发工具。
- macOS 包声明最低系统为 macOS 13；Apple 插帧需要 macOS 26 或更新版本。当前本机验证为 Apple Silicon，较旧系统与 Intel Mac 尚未完成兼容性验收。
- iPad 版最低 iPadOS 26，安装到真机需要在 Xcode 中配置自己的签名账号。详见 [iPad 使用和构建说明](iPad/README.md)。
- 采集设备必须支持 UVC；音频还需设备提供可用的 USB 音频输入。HDMI 直通规格不等于 USB 采集规格。

## 构建与使用 macOS 版

```sh
git clone https://github.com/Nakiha/SwitchViewer.git
cd SwitchViewer
Scripts/build-app.sh
open SwitchViewer.app
```

构建脚本生成 Release 应用及游戏插帧动态库，并使用本机 ad-hoc 签名。它不是 Developer ID 签名或 Apple 公证的发布包。

可公开下载的版本会放在 [Releases](https://github.com/Nakiha/SwitchViewer/releases)。本机生成安装压缩包及校验值使用 `Scripts/package-release.sh`；版本与发布流程见 [Release 说明](Docs/releasing.md)。

1. 将游戏设备的 HDMI 输出接入 UVC 采集卡，再将采集卡连接到 Mac。
2. 从工具栏选择视频采集设备及设备实际支持的分辨率、帧率，并授予相机权限；监听采集卡音频还需麦克风权限。
3. 按需开启插帧。屏幕捕获另需系统的屏幕录制权限。
4. 游戏内插帧通过启动目标进程并加载 Metal hook 实现，属于实验功能；目标进程不允许加载时无法使用。接入方式、测试程序及限制见 [游戏内插帧说明](Artifacts/game-injection.md)。

游戏适配为插件结构：当前仅内置鸣潮插件，启动面板只展示已注册的游戏。新增游戏需实现并注册对应插件。插件开发入口见 [游戏插件说明](Docs/game-plugins.md)。

macOS 处理面板可配置 2× / 4× / 8× 和插帧延迟容忍量；默认 2× 保留原有策略。
预算不足时丢弃超时插值帧，实际输出受算力与屏幕刷新率限制。详见 [倍率与延迟配置](Docs/interpolation-options.md)。

## 验证

```sh
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
Scripts/build-app.sh
Scripts/build-ipad-app.sh device
Scripts/build-ipad-app.sh simulator
```

iPad 构建默认不签名，用于编译验证，不能直接安装到真机。macOS 桌面会话还可执行 `Scripts/check-ui-workflow.sh` 检查工具栏、预览和会话切换；该检查会打开测试窗口。需要 GPU 与桌面会话的检查不适合无图形环境。

性能回放和压力测试流程见 [逐帧诊断说明](Artifacts/frame-trace-workflow.md)。编译或测试通过不代表所有设备兼容，也不代表稳定倍帧或更低的操作延迟。

GitHub 自动检查运行 Swift / Python 回归、macOS 发布构建和 iPad 双目标构建。硬件不可用时相关测试会明确跳过；桌面交互与真实设备仍单独验收。完整状态见 [兼容性与验证边界](Docs/compatibility.md)。

## 已知限制

- 插帧需要额外缓冲与 GPU 运算，会增加画面等待时间；界面的 App 内耗时不等于从手柄输入到显示的端到端延迟。
- 高分辨率插帧可能使用最高 1080p 代理生成后放大，不代表原生 4K 中间帧；运动、遮挡和文字边缘可能出现瑕疵。
- iPad 音频尚未按插帧视频缓冲补偿，开启插帧可能音画不同步；长期运行、温度、续航与采集卡模式兼容性仍待验证。
- 游戏内 hook 当前主要针对单个 SDR BGRA Metal 主画面，HDR、多视口及其他提交接口未全面验证。目标游戏的保护机制与兼容性需要逐项确认。

## 代码结构与反馈

- `Sources/SwitchViewer/`：macOS 界面、采集与呈现。
- `Sources/SwitchViewerInterpolation/`：插帧、帧率检测、队列与呈现策略。
- `Sources/SwitchViewerGamePlugins/`：游戏识别、安装发现与画面筛选插件。
- `Sources/GameMetalHook/` 和 `Sources/SwitchViewerGameHook/`：实验性 Metal 接入。
- `iPad/`：iPad 应用和共享 Xcode scheme。
- `Tests/`：回归测试及可重复使用的输入；`Artifacts/`：实验记录与性能分析。

欢迎提交 Issue 或 Pull Request。故障反馈请附系统版本、芯片、应用版本或提交号、采集卡型号及模式、插帧开关、复现步骤和预期行为。macOS 日志位于 `~/Library/Logs/SwitchViewer/`；上传前请检查并移除个人路径、设备标识和游戏账号信息。分享性能数据时请同时记录输入内容帧率、实际呈现帧率、测试场景与测量方法。

开发流程见 [贡献指南](CONTRIBUTING.md)，版本变化见 [更新记录](CHANGELOG.md)。

## 许可证

[MIT License](LICENSE)，Copyright © 2026 Nakiha。

## 对比视频素材

工具页可同时录制原始采集与插帧后素材，最长 30 秒，供并排或擦拭剪辑使用。操作方法与素材范围见 [录制说明](Docs/comparison-recording.md)。
