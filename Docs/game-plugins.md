# 游戏插件

游戏适配采用编译时注册的 Swift 插件。首版内置鸣潮适配与通用 Metal 回退；选择其他 Mac 游戏会按 Bundle Identifier 自动匹配，未匹配时使用通用插件。通用入口属于实验性适配，不能保证任意游戏可用。

## 职责与数据流

`GameIntegrationPlugin` 位于 `Sources/SwitchViewerGamePlugins/`，负责：

- `descriptor`：稳定插件 ID、名称、Bundle Identifier、安装位置和可选安装链接。
- `matches(_:)`：应用识别；默认按 Bundle Identifier，应用重命名不影响识别。
- `acceptsSurface(_:)`：画面筛选；默认排除插帧自己的输出，限制最小尺寸和已验证的 SDR 像素格式。

启动器查找游戏后，将插件 ID 写入 `SWITCHVIEWER_GAME_PLUGIN`。游戏内动态库从同一份 `GamePluginRegistry` 取得插件，Metal 的 `nextDrawable` 接入调用其画面筛选策略，再交给共享 `GameInterpolator` 完成纹理复制、Apple 插帧、队列调度和回退。`LOADED` 日志包含插件 ID，便于反馈。

未设置插件 ID 的旧诊断脚本使用 `generic-metal`。显式填写未知 ID 时不捕获画面并记录错误，避免自动套用错误适配。插帧代理分辨率、垂直同步和呈现节奏仍由用户设置，插件不会覆盖这些设置。

## 新增插件

1. 在 `Sources/SwitchViewerGamePlugins/` 新建遵循 `GameIntegrationPlugin` 的不可变类型。
2. 定义唯一 ID 与应用 Bundle Identifier；需要安装发现时填写候选路径，允许应用移动时依靠 Bundle Identifier 查询。
3. 如需特殊画面筛选，重写 `acceptsSurface`，保持纯计算、无锁等待、无 UI 或文件 I/O。它可能由游戏的渲染线程调用，必须排除 `SwitchViewer.Interpolation` 输出层以避免递归捕获。
4. 将实例加入 `GamePluginRegistry.builtIn.plugins`。启动面板会自动生成对应入口，不需要添加新的游戏按钮逻辑。
5. 在 `Tests/SwitchViewerGamePluginsTests/` 覆盖匹配、非目标应用、画面筛选与安装发现，并记录真实游戏的兼容性结果。

当前扩展点为识别、发现及画面准入；新的纹理格式、不同渲染接口或底层同步策略还需扩展共享核心。插件是与应用一起构建的源代码模块，当前没有外部二进制加载或运行时下载安装接口。
