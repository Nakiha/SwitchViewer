# Release 流程

`Version.json` 是 macOS 与 iPad 的版本来源。`version` 为 `主.次.修订`，`build` 为递增正整数。修改后运行 `python3 Scripts/generate-ipad-project.py` 更新 Xcode 构建设置；生成器保留本机签名选择，提交前移除个人 Team。

macOS 构建每次重新写入 Info.plist，更新已有 App 的版本、权限和来源提交号。包内 `Contents/Resources/BUILD-INFO.json` 记录版本、构建号、源码提交、SDK、工具链、架构与签名状态；未提交源码构建标记 `+dirty`，正式上传使用干净工作区。

## 本机生成包

```sh
Scripts/package-release.sh
cd dist
shasum -a 256 -c SwitchViewer-0.2.0-macos-arm64.zip.sha256
```

产物名称包含版本和实际架构，位于被忽略的 `dist/`。当前使用 ad-hoc 签名，不能声称已经公证。初始下载包仅提供 arm64；iPad 请按其 README 自行签名安装。

## 发布到 GitHub

1. 更新版本、`CHANGELOG.md` 和 `Docs/releases/v版本.md`，完成测试、构建及对应真机验收。
2. 提交并推送代码，确认 CI 结果与兼容性说明一致。
3. 在该提交创建与 `Version.json` 一致的 tag，例如 `git tag v0.2.0`、`git push origin v0.2.0`。
4. tag 的 CI 通过后会自动创建 **草稿预发布**，附构建包、SHA-256 和对应版本说明。
5. 在 GitHub 草稿中检查资产、版本、架构和已知限制，再由维护者正式发布。草稿不会自动公开给社区。

GitHub `xcode-27` 镜像仍为预览环境，构建日志记录实际工具链。当前云端虚拟机无法完成 Apple 帧处理，CI 显式跳过两项对应实机测试，其余回归和 Metal 色彩测试仍运行；正式宣称硬件能力需本机或真机结果。本机默认启用全部测试。桌面工作流检查不在云端运行。

后续 Developer ID 签名和公证需要维护者的证书与 Apple 凭据。目前没有配置这些凭据；证书和密码不得写入仓库。
