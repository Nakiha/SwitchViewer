# v17 原分辨率呈现等待定位

## 已确认的范围

清晰档（1080p 中间帧）逐帧埋点把提交之后拆开：

| 原帧阶段 | P50 |
| --- | ---: |
| command.commit 调用 | 0.0085 ms |
| commit 开始 → GPU 开始 | 0.290 ms |
| GPU 执行 | 0.356 ms |
| 调度回调 → drawable.present 调用 | 0.0025 ms |
| drawable.present 调用 → presentedTime | 23.417 ms |
| GPU 完成 → presentedTime | 22.754 ms |

这是同序号关联的阶段分布，各独立 P50 不能相加当作一帧精确总和。它确认尾部不主要来自本程序的 commit 阻塞、GPU 排队或最终绘制；Metal 呈现调用已经及时发生。不能将 GPU 完成到 presentedTime 的整段直接命名为 WindowServer 某个内部队列，也不包含输入和物理扫描/光子测量。

新增记录：commandCommitBegin/End、gpuScheduledCallback、gpuStart、drawablePresentCalled。实际 drawable 方法由 C hook 观测，并带序号及 immediate/atTime/minimumDuration 标识；GPU 开始/结束来自 command buffer 硬件时间，scheduled 回调只是 CPU 观察时间。新增窗口状态：全屏、输出像素尺寸、屏幕最大刷新率、输出层同步开关。屏幕最大刷新率不是当前实际可变刷新率。

## 不降分辨率的隔离对照

使用鸣潮实际源帧间隔回放，所有下表试验保持清晰档；源帧执行真实 GPU 渲染，Apple 插帧与显示执行真实系统 API。12 秒轮次不是相同 GPU 负载的严格 A/B，不能当作真实鸣潮新版本实测。

| 输出结构 | 同步 | fps | 原帧 P50 / P95 ms | present 调用→显示 P50 ms |
| --- | --- | ---: | ---: | ---: |
| 正常原画面 + 覆盖层 | 开 | 约 83 | 42.58 / 48.30 | 23.42 |
| 离屏源，只保留可见覆盖输出 | 开 | 83.23 | 42.08 / 47.59 | 23.67 |
| 离屏源，唯一输出设为窗口根层 | 开 | 82.83 | 42.77 / 47.61 | 23.32 |
| 根层输出 + 全屏切换 | 开 | 80.37 | 44.19 / 49.26 | 23.52 |
| 根层唯一输出 | 关 | 81.75 | 32.96 / 45.35 | 12.21 |
| 正常原画面 + 覆盖层 | 关 | 81.67 | 33.33 / 47.06 | 12.52 |

离屏源只用于测试窗口，它通过 scratch texture 产生原帧，并在其 GPU 完成后执行捕获，不是伪造 Metal 呈现回调。它没有原生呈现，因此没有 nativePresented 配对；检查器需要显式 --offscreen-producer 且确认原生呈现数为零。正常路径保留原生配对检查。

单输出、根层和全屏都未明显减少尾部，因此此前“游戏与覆盖层两套呈现就是主因”的猜测没有得到支持。同步开关则在两种结构都将尾部减少约 11 ms：同步相关的显示等待/排队是一个主要可控因素。此结果不证明关闭后没有撕裂，也不证明剩余等待全部来自某个已知系统队列。

Apple 明确说明关闭 displaySyncEnabled 可以更快呈现，但可能产生撕裂：[官方说明](https://developer.apple.com/documentation/quartzcore/cametallayer/displaysyncenabled?changes=__4&language=objc)。不能把此路径直接默认为“无画质代价的优化”。正常双路试验 P95 仍约 47 ms，截止丢弃 54 个，帧率没有同时提升；同步开启时校准的提交和接纳策略还需针对更快的路径研究，追求低 P50 不能掩盖尾部和中间帧损失。

## 系统 Trace 的边界

已使用本地 xctrace 的 Metal System Trace 记录测试窗口。导出 ca-client-present-request 1423 行、ca-client-presented-handler 1418 行、display-surface-queue 2014 行以及 command-buffer 完成事件；但是 compositor/displayed-surfaces/swap 的详细表没有有效行。不能据此宣称已定位具体 WindowServer 内部等待环节。原始 trace 及导出位于 /tmp，结论只使用测试窗口及阶段观测，不发布系统其他进程数据。

## 提供给实际游戏的显式开关

v17 在“来源 → 游戏 → 呈现”加入垂直同步复选框，默认开启。关闭只改变本程序输出层，不改变游戏渲染分辨率、中间帧清晰档或游戏原生层的同步属性；选择保存到偏好，下次通过 App 启动游戏生效。提示说明关闭可能撕裂。启动环境 SWITCHVIEWER_GAME_DISPLAY_SYNC=0 关闭，默认/其他值开启。

这是方便实机验证的选择，不是已经确认的鸣潮低时延收益。用户的运行中游戏未被重启或修改配置。

## 校验

44 项 Swift 与 8 项 Python 测试通过。分析器新增分阶段回归，检查器验证完整阶段时间顺序、帧序、重复提交、过期提交和 GPU/复制像素顺序。正常同步回放 521 个正确像素/写入顺序样本，978 个完整呈现阶段；离屏覆盖/根层分别 529 个像素样本、981/977 个完整阶段；正常双路关闭同步 531 个像素样本、967 个完整阶段，全部无帧序倒退、重复提交、绝对期限越界或记录丢失。

关闭同步后只有 7 个原帧得到旧提前预算，原因是较少的呈现延后不再满足该预算学习门槛；不能要求旧同步负载下的 minimum-advanced-originals=100 覆盖条件。仍执行所有顺序与有界等待检查。

启动/全屏过渡有短暂空洞，本轮短回放不证明长时间游戏永不卡顿。未引入真实游戏原生 Drawable 接管，因为隔离结果不支持为了这一步冒引擎兼容性风险。

正式环境开关再次复测（未使用 fixture 的 unsynced 参数）：SWITCHVIEWER_GAME_DISPLAY_SYNC=0 + clarity。输出 81.66 fps，原帧 P50 33.25 ms / P95 46.93 ms，呈现调用→显示 P50 12.53 ms。530 个正确像素及写入顺序样本、966 个完整呈现阶段；零顺序/重复/绝对期限错误和记录丢失，无 >=60 ms 的整段呈现空洞。59 个状态样本均 syncEnabled=false、窗口非全屏、屏幕最大刷新率 120。原帧 max 90.45 ms 是独立样本，不能以没有整体显示空洞将其抹掉。

Scripts/build-app.sh、deep/strict 签名与 diff 空白检查通过。根目录 SwitchViewer.app 更新为 v17。
