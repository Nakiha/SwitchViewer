# SwitchViewer for iPad

现有仓库内的独立 iPad App，最低 iPadOS 26。目标设备为 13 英寸 M5 iPad Pro，支持竖屏与横屏。

Mac App 继续使用原有 Swift Package 和 `Scripts/build-app.sh`。iPad 工程直接引用 `Sources/SwitchViewerInterpolation` 中选定的公共源文件；不包含 Mac 窗口、屏幕捕获和游戏注入代码。

## 首版内容

- UVC HDMI USB 采集卡发现、设备热插拔、分辨率与帧率选择，默认 1080p60，可选最高 4096×2160 的 4K 及 720p、30fps 等设备实际报告的模式。4K HDMI 输入 / 直通不等于 USB 4K 采集，菜单只展示 UVC 设备报告的模式。
- 全分辨率 NV12 视频采集，关闭系统自动预览降采样，Metal / Core Image 等比全屏呈现，黑边填充，保持设备报告的色彩信息。
- 复用 Mac 版 Apple 低延迟插帧器，按内容更新生成中间帧，支持运行时开关和失败后回退到原始画面。
- 有界呈现队列，丢弃过期中间帧；重新开始或切换模式时拒绝旧会话异步结果。
- 可选 USB 音频直通，使用 iPad 扬声器或当前耳机输出。仅监控 USB 音频，不使用内置麦克风。
- 显示实际收到的采集分辨率、采集帧率、内容更新帧率、实际呈现帧率和 App 内呈现时间；显示 App 版本用于确认更新。
- 隐藏控制栏后，眼睛按钮在 3 秒无触摸时自动消失，轻点画面可重新显示。
- 无采集卡时可播放 720p30 移动方块演示。在模拟器中禁用 Apple 插帧，保留界面、视频呈现和演示路径。模拟器呈现指标以 GPU 完成为近似，真机使用 drawable 实际呈现回调。
- 切入后台暂停采集和声音，返回前台恢复播放；播放期间避免自动锁屏。

## 在自己的 iPad 上安装

1. 用 Xcode 打开 `iPad/SwitchViewerIPad.xcodeproj`。
2. 选择 `SwitchViewerIPad` target，在 **Signing & Capabilities → Team** 选择自己的 Apple 账号。工程未填写他人的 Team 或证书。
3. 若默认 Bundle Identifier 已被占用，将 `com.zhu.switchviewer.ipad` 改成自己的唯一标识。
4. 通过 USB 连接 iPad 与 Mac，在 iPad 上信任此电脑，并按 Xcode 提示启用 **开发者模式**。
5. 选择 iPad 为运行设备，点击 Run。安装完成后可断开 Mac，再连接采集卡。
6. 若首次启动提示开发者未受信任，在 iPad 的 **设置 → 通用 → VPN 与设备管理** 中信任自己的开发者账号，并保持设备联网完成验证。
7. 首次播放同意相机权限；开启声音时同意麦克风权限。系统使用相机 / 麦克风权限管理 USB 采集设备。

免费 Personal Team 的签名通常 7 天有效，过期需要重新运行安装。TestFlight 或 App Store 分发另需开发者会员和分发流程。

### 无线更新

完成有线配对后，可以让 iPad 和 Mac 连接同一局域网，解锁 iPad，再通过 Xcode / devicectl 无线安装更新，不占用连接采集卡的 USB-C 接口。局域网需要允许设备发现、互相通信和 IPv6；仍需由 Mac 编译、签名和安装，不是 App 自行在线更新。

Xcode 27 使用 **Xcode → Open Developer Tool → Device Hub** 管理设备；旧版 Xcode 在 **Window → Devices and Simulators** 中提供 **Connect via network**。如果无线不可用，可以临时连接 USB 安装，之后再排查网络发现与配对状态。仅询问无线更新不要求升级 iPadOS。参考 [Apple 设备连接文档](https://developer.apple.com/documentation/xcode/managing-your-simulated-and-physical-devices-in-device-hub)。

连接：Switch 底座 HDMI 输出 → UVC 采集卡 → iPad USB-C。需要边充电边采集时使用支持 USB 数据和 PD 供电的扩展坞。

## 构建验证

```sh
Scripts/build-ipad-app.sh device
Scripts/build-ipad-app.sh simulator
swift test
```

构建脚本默认不签名，仅验证编译；产物位于 `.build/ipad-device` 或 `.build/ipad-simulator`，不能直接安装到真机。安装使用上述 Xcode 签名步骤。

工程和共享 scheme 已提交到目录，不需要 XcodeGen、CocoaPods 或其他第三方生成工具。新增 App 源文件后可以运行 `python3 Scripts/generate-ipad-project.py` 更新工程；生成器保留已有 Team 和 Bundle Identifier，方便继续安装到已配对设备。

## 0.1.2 格式选择修复

- 每秒更新的播放统计移到独立观察对象，仅刷新统计视图，不再刷新设置菜单和格式选择器。
- 画面格式改为独立列表页面，滚动选择后返回设置。
- 标签保留真实的 60 / 59.94、30 / 29.97 差异，并显示 NV12、YUY2、MJPEG 等采集编码。
- 选项身份包含编码，启动时按对应编码、分辨率及准确帧间隔匹配设备模式，避免使用其他同尺寸格式。
- 分数帧率使用标准视频时间基，按设备报告的帧间隔范围检查可用性。
- 新增五项格式回归测试，连同现有测试共 72 项通过；真机和模拟器目标编译通过。UI 滚动稳定性和采集卡各模式仍需真机确认。

## 当前验证边界

已通过 iPad 真机目标和模拟器目标的编译，以及共享库的 72 项测试。2026-10-04 已使用 Personal Team 签名，将 Release 0.1.0（build 1）安装到 13 英寸 M5 iPad Pro（iPadOS 26.6），用户完成开发者信任后反馈可以使用。0.1.1（build 2）补充了 4K 模式、实际采集分辨率显示和眼睛按钮自动隐藏。最新 0.1.2（build 3）已通过 USB 更新安装并由 devicectl 启动，设备确认安装版本为 0.1.2（3），进程正在运行。格式列表滚动稳定性、采集卡各模式、声音同步和真机插帧性能仍需进一步验证。无线连接仍未验证成功。

4K 模式原始帧保持采集分辨率；插值帧使用现有 Apple 1080p 代理生成，再等比放大显示。因此 4K 采集不代表逐帧原生 4K 插帧。

插帧模式为等待相邻帧加入缓冲，首版缓冲约为两个内容帧间隔加 8ms（典型 60fps 约 41ms、30fps 约 75ms），不包括采集卡和 Switch 自身延迟。关闭插帧时直接提交最新采集画面。

音频目前直接播放，未按插帧画面缓冲作同步补偿，插帧开启时可能音画不同步。实际 USB 音频路由、720p/1080p 插帧性能、120Hz 显示、发热和续航需要 M5 iPad 真机验证。性能测试应使用 Release 配置。

真实游戏经 60fps 采集可能包含重复帧；首版按采样画面检测内容重复及切镜，尚需用 Switch 游戏确认 30fps / 60fps 切换和误判情况。
