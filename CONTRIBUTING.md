# 参与开发

先阅读 [README](README.md) 与 [兼容性和验证边界](Docs/compatibility.md)。使用 Xcode 27，基础验证为：

```sh
swift test
python3 -m unittest discover -s Tests -p 'test_*.py'
Scripts/build-app.sh
Scripts/build-ipad-app.sh device
Scripts/build-ipad-app.sh simulator
```

修改 macOS 界面、来源切换或启动器时，另在本机桌面执行 `Scripts/check-ui-workflow.sh`。修改 Metal hook 时使用测试窗口验证 command buffer 和直接 drawable 呈现，确认退出、尺寸变化与原画面回退。实际游戏启动属于设备验收，不是贡献者提交代码的必需条件。

GitHub CI 使用 `xcode-27` 预览镜像。没有 Metal 或 Apple 插帧能力的机器会明确跳过相应硬件测试，跳过不等于硬件验证通过；桌面交互、采集卡热插拔和真机性能仍需本机检查。

新游戏接入请新增 [游戏插件](Docs/game-plugins.md)，不要把游戏安装路径、商店链接或识别逻辑写进通用捕获与呈现代码。保持修改目的明确，并补充能捕获实际回归的测试。

不提交安装包、原始录像、像素读回、大型日志、个人签名 Team、Xcode 用户状态或凭据。小型、脱敏且可复用的回归输入放在 `Tests/Fixtures/`。报告性能改进时说明硬件、输入场景、采样区间与延迟定义；不能只引用“生成帧率”。

发布流程与版本约定见 [Release 流程](Docs/releasing.md)。
