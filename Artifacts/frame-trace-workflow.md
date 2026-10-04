# 鸣潮逐帧记录与节奏回放

2026-10-03，当前 prepared-pair-v24。原帧提前提交、释放边界与试验结果见 `latency-overlap-v14.md`；v13 口径见 `midpoint-admission-v13.md`，v12 实测见 `early-capture-v12.md`。

## 连续记录

重启 SwitchViewer，并通过它重新启动鸣潮，使进程加载新库。进入正常游戏场景后，在悬浮工具栏的 **快捷键 → 记录 30 秒** 启动记录。记录窗口为 30 秒，到期自动停止，每条记录有独立 traceID。按钮通过进程专属 Darwin 通知请求记录，收到游戏日志确认后才显示“正在记录”，完成后显示“记录已保存”；3 秒内没有确认会显示未响应。旧游戏进程未加载控制入口时按钮禁用并提示重启。游戏内 **⌥⇧T** 仍保留，但鸣潮实测没有收到此键盘事件，优先使用按钮。

记录只包含数字时间戳、序号和丢帧原因，不包含游戏画面。日志仍在 `~/Library/Logs/SwitchViewer/GameInjection/`。录制期间每秒批量输出，JSON 编码与写入在独立 utility 队列完成；实时 UI 跳过逐帧 JSON。缓冲上限 4096 条，超限会输出 `FRAME_TRACE lost=...`，分析时必须检查这一项。

事件：游戏提交、捕获 GPU 回调、已接受输入、原帧转换就绪、插帧就绪、显示调度、Drawable 获取排队及起止、实际提交、GPU 完成、实际显示、丢弃与未确认呈现。序号为偶数的是原帧，为奇数的是中间帧。`source` 是源帧时间；中间帧还记录 `currentSource`；所有时间与 processing/algorithm 持续时间单位均为秒。原帧转换就绪前的时间包含捕获 GPU、队列等待和转换，不能单独解释为转换耗时。

```sh
python3 Scripts/analyze-frame-trace.py ~/Library/Logs/SwitchViewer/GameInjection/<游戏日志>.log --out Artifacts/wuwa-continuous
```

输出同一帧配对的 P50/P95、原帧/中间帧参考年龄、实际显示帧率、丢弃时剩余时隙和帧序错误，同时导出 `wuwa-continuous-cadence.json`。默认分析最新 traceID，可用 `--trace-id` 指定。录制边界可能缺少部分帧的早期事件，只有配对完整的阶段进入对应统计。

## Metal 回放

```sh
env DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" SWITCHVIEWER_GAME_HOOK=1 SWITCHVIEWER_FRAME_TRACE=1 .build/release/GameHookFixture --cadence="$PWD/Artifacts/wuwa-continuous-cadence.json"
```

回放按游戏原始提交间隔循环运行，实际转换、Apple 插帧和 Metal 呈现继续执行。主线程长时间阻塞后不会生成补帧突发。加入 `--drawable-stall-test` 可在第 4 秒后模拟一次 Drawable 获取等待 1 秒；加入 `--pressure-test` 可在第 4–8 秒额外延迟插帧回调 15 ms；`--stall-test` 可模拟主线程阻塞；`--smoke-test` 会在 12 秒退出。完整 30 秒录制应等待 `FRAME_TRACE end` 后再关闭窗口。

回放只复现提交节奏，不复现鸣潮的纹理内容、GPU 竞争与 WindowServer 负载，因此不能把其显示时延当作鸣潮实测结果。

## 本轮已有实际数据

`wuwa-v6-rewind-analysis.json` 配对了现有 v6 鸣潮停顿倒带中的 86 帧，按帧序号去重：53 个原帧、33 个中间帧。原帧提交到显示的中位数约 22.9 ms，中间帧约 19.7 ms。这些是偏向停顿现场的样本，不能代替稳态采集。

`wuwa-rewind-cadence.json` 包含从倒带提取的 131 个输入间隔，平均约 41.3 fps，并非恒定 45 fps；用于验证抖动与恢复。倒带里少量中间帧在名义时隙尚余 1–9 ms 时进入 dropPastExpiry，但倒带记录时刻早于最终检查，必须用连续记录确认实际提交时刻，不能据此直接移除保护。

下一步比较固定视角、转动镜头和战斗三个 30 秒窗口，检查中间帧处理完成后到提交之间的等待，以及原帧提交是否抢先。只有实际帧序、交付率和呈现间隔均受控时，再调整过期保护或延迟预算。

## 记录器和回放验证

`wuwa-cadence-replay.json` 是以倒带节奏运行测试窗口的 30 秒连续记录分析，包含 1236 个游戏提交、1232 个已接受输入、2143 次实际呈现。零缓冲丢失、零帧序错误；输出约 72.2 fps，不能解释为鸣潮帧率，因为输入节奏平均约 41.3 fps 且包含抖动。原帧 P50 47.0 ms，GPU 完成到显示 P50 19.9 ms，Apple 插帧处理 P50 13.9 ms，包含转换和回调等待的处理链 P50 14.9 ms。正式策略仍会丢弃部分中间帧：过期保护 87 次、较新帧抢先 81 次、算法忙跳过 127 次、错过时隙 19 次。

Swift 37 项测试、Python 分析器 5 项测试通过；release 构建及签名验证通过。原始回放事件日志保留在 `/tmp/switchviewer-frame-trace-replay.log`，可用分析脚本重新生成结果。

## 正常战斗卡顿分析

见 [wuwa-v8-lag-analysis.md](wuwa-v8-lag-analysis.md)。连续记录确认一次 1050 ms 呈现间隔，期间源帧及插帧持续生成。v9 的故障注入验证中，获取等待 1001 ms 期间主线程仍处理 89 次调度和 45 次源帧提交，零过期提交、零帧序错误。模拟结果验证线程隔离，不代表已定位或解决鸣潮实际卡顿。

## v10 呈现链埋点（schema 2）

重新启动 SwitchViewer，并通过它重新启动鸣潮，日志应出现 `pipeline=adaptive-v10`。工具 → 记录 30 秒的操作保持一致。建议在固定视角、转动镜头、正常战斗各录一轮；记录期间保持游戏可见，完成后再切回其他窗口。

新增独立 `captureID`：gameInput、captureComplete、input、originalReady 与原游戏 drawable 的 nativeGpuComplete/nativePresented/nativeUnconfirmed 可配对；它与插帧输出 sequence 分开，捕获因 busy 跳过时仍可测量原游戏提交。原游戏 handler 仅在录制期间注册。

- `nativeSubmitToDisplayMs`：原游戏提交钩子到其 drawable 呈现确认。
- `nativeGpuToDisplayMs`：同一原游戏 command buffer 的 GPU 完成到 drawable 呈现确认。
- `overlayMinusNativeDisplayMs`：同一 captureID 的插帧层原帧呈现减原游戏呈现；允许负值，不与中间帧混算。
- `drawableReturnedToMain` / `drawableReturnToMainMs`：获取结束到主线程接收；与获取本身耗时分开。
- `callbackTime`：GPU/呈现 handler 实际执行时刻；分析 GPU 时间戳到回调的等待。GPU 回调延迟包括未确认呈现的帧。
- `displayState`：每 200 ms 在主线程采样 overlayHidden、applicationActive、windowVisible/windowOccluded 和 pendingPresentation/pendingGPU/pendingAcquisition。找不到源层所属 NSWindow 时窗口字段缺失，表示未知。activity 与 occlusion 不相等。
- `overlayVisibility`：每次隐藏/显示切换记录原因，例如 noSlot、noDrawable、noPresentation、staleReady；包含切换时未完成回调数。
- `submitted`：附带 pending 三项计数；pendingPresentation 包含本次提交。

pendingPresentation/pendingGPU 统计的是尚未在主线程登记完成的回调，不是实际 GPU 硬件队列深度。原游戏 drawable 呈现确认也不意味着它在插帧覆盖层下的像素可见。原 command buffer 在 hook 中还包含捕获 blit，因此不能把 native 结果当作完全未注入的基线。

分析器兼容 schema 1，不强行配对缺失 captureID 或录制边界缺失的事件。新增状态与回退事件随 30 秒记录保存；录制窗口之外仍使用已有常驻停顿倒带，并非全天完整逐帧记录。

验证：Swift 37 项、Python 分析器 7 项测试通过；release 构建、签名与 diff 检查通过。45 fps 测试窗口验证了原游戏/插帧层配对、可见性字段和获取返回主线程时间；额外的 1 秒获取等待故障注入记录确认捕获了 noSlot 隐藏/恢复，见 v10-trace-check.json。普通窗口记录见 v10-normal-check.json。模拟数据不代表鸣潮性能。

## v11 直接呈现入口修正

鸣潮 v10 实测没有 nativePresented：直接 present 的捕获发生在已经呈现后的回调里。v11 在 Objective-C 原有回调中保存 native 请求、呈现和回调时刻，连同 captureID 配对；该路径不再把 hook 复制 buffer 的 GPU 时间当作游戏 GPU 时间。captureRoutes 区分 directAfterPresented 与 commandBufferBeforePresent。v10 原游戏 GPU 数据在该路径下无效，不能作为原游戏基线。详见 wuwa-v10-record-review.md。

## v12 提前捕获回归

`gameInput.reason` 区分 `directAfterGPU`、`directAfterPresented` 和 `commandBufferBeforePresent`。`captureFallback` 记录未找到写入、尚未提交或多队列等降级原因。原游戏 GPU 结束时间与捕获入口以 captureID 配对，不能用捕获复制命令的结束时间替代原游戏 GPU 结束时间。

```sh
python3 Scripts/check-early-capture.py <日志> --expect-route directAfterGPU --validate-copy
```

`--validate-copy` 仅用于带同名参数的 GameHookFixture：每帧颜色标记经过实际 GPU 复制与回读比对；生产游戏不会回读像素。`--direct-in-flight` 检查 GPU 尚在执行的直接呈现，`--direct-before-commit` 检查未提交时降级，`--native-present-lead-ms=20` 用于受控呈现等待。环境变量 `SWITCHVIEWER_CAPTURE_AFTER_PRESENT=1` 强制旧流程用于对照。

`nativeRequestToOverlayDisplayMs` 是同一原帧请求原生呈现到插帧层实际显示的直接测量；`overlayMinusNativeDisplayMs` 是两层显示同一原帧的差。Panel 的“取帧→显示”起点随捕获提前而变化，跨版本比较应使用前两项。它们仍不包含输入、游戏逻辑以及请求呈现前的渲染时间。

## v13 中间帧准入与主指标

`submissionReserve` 记录截止检查的实际预留时间。Fixture 可用 `--strict-midpoint-deadline` 恢复旧检查做同版本对比。v13 `latencyP50/P95` 只统计原帧捕获→显示；旧的原帧/中间帧参考混合 P50/P95 另存 `allReferenceAgeP50/P95`。不要把口径修正当作时延改善。分析器新增原帧转换就绪→提交、提交→GPU→显示以及提交领先 B 捕获的逐帧配对时间。

## v14 原帧提交顺序

`submissionAdvance` 记录最多 4 ms 的预算；`originalSubmissionHeld` 记录等待前一中间帧解决以及原提交期限。`--check-midpoint-gate` 验证已暂缓的原帧不会在中间帧解决前提前提交。`--minimum-advanced-originals=100` 可要求优化路径的样本覆盖；低负载、提前显示或尺寸频繁变化下，预算可以自然为零，不应将零预算本身当作功能失败。

### v15 成对提交仲裁

当前版本 `adaptive-v15`。原帧主动调度其前一已就绪中间帧；中间帧获取 Drawable 时保有提交位置，最长只比旧原帧提交时刻多等 1 ms。未完成算法没有额外等待。中间帧解决后通过异步回调唤醒原帧，保留绝对截止兜底。

`originalSubmissionHeld.deadline` 是旧提交时刻，新增该事件的 `expires` 是本次仲裁等待上限；不是图像的绝对过期时间。`--legacy-pair-submission` 仅测试窗口有效，用于关闭主动调度与额外等待。逐帧检查器验证 1 ms 所有权上限、无重复提交和绝对期限。详见 `frame-submission-v15.md`。

### v16 插帧偏好

当前正式标识 `adaptive-v16`。来源 → 游戏可选择清晰优先或低时延（最高 720p），下次启动生效。启动环境 `SWITCHVIEWER_GAME_PROFILE=lowLatency` 限制中间帧代理宽度为 1280，原帧保留捕获分辨率；默认/未知值使用清晰档。日志新增 `INTERPOLATION_PROXY width=… height=…` 与 `PRESENT_PATH`，可核对代理和呈现设置。尺寸变化保留所选代理上限。详见 `latency-profile-v16.md`。

### v17 呈现阶段定位

当前 `adaptive-v17`。新增 commandCommitBegin/End、gpuScheduledCallback（CPU 回调观测）、gpuStart（硬件时间）、drawablePresentCalled（实际方法调用，含呈现模式）。displayState 增加 windowFullscreen、surfaceWidth/Height、screenMaximumFPS、syncEnabled；最大刷新率不代表当前刷新率。

来源 → 游戏 → 呈现新增“垂直同步”，默认开启，下次启动生效。SWITCHVIEWER_GAME_DISPLAY_SYNC=0 仅关闭本程序输出层同步，不降低插帧分辨率，可能撕裂。诊断已在正常双路回放复现尾部从约 23 ms 缩短到约 12.5 ms，但帧率与尾延迟仍需适配，尚非实际鸣潮收益保证。详见 presentation-localization-v17.md。

检查器 --check-presentation-stages 验证完整阶段顺序。--offscreen-producer 仅用于没有原生呈现的隔离 fixture，要求 nativePresentedCount=0；默认仍严格要求原生配对。关闭同步时，旧 minimum-advanced-originals=100 条件不适用，保留其他有界等待校验。

## v18 呈现时钟诊断

同一录制按钮或 ⌥⇧T 现在同时记录 displayTick（预测时钟）、所在屏幕和 drawableID。分析结果 presentationWaitDiagnostics 下有逐帧节拍关联及按原帧/中间帧、前方已确认等待帧数量分组的尾部耗时。它用于判断等待是否随排队或节拍变化，不直接测量 WindowServer 内部队列或物理扫描。详见 presentation-clock-v18.md。更新后的 hook 要在下一次通过 App 启动游戏时加载。

## v19 无同步呈现策略

关闭垂直同步时自动启用立即呈现与按排队压力学习的中间帧接纳预算。submitted.reason=unsyncedAdaptive；开启同步为timedCalibration。分析器新增presentationExpiryChecks，分开检查实际呈现是否晚于名义窗口。详见unsynced-submission-v19.md。原有录制流程不变。

## v20 快捷键入口

“快捷键”tab集中显示游戏⌥⇧I（插帧开关）和⌥⇧T（记录30秒），并提供无需游戏焦点的开关与录制按钮。工具tab继续用于诊断、日志和测试窗口。按钮开关由游戏PAUSED/RESUMED确认；旧hook提示重新加载。v20不改变v19上屏策略。

## v21 自动压力回放与布局修复

来源页的状态行已纳入纵向布局，使用单行截断并保留完整 tooltip，面板按可见内容 fittingSize 计算高度，避免启动/退出按钮和状态叠在一起。

正式游戏保留 v19/v20 已验证的无同步提交策略。新的基于实际 presentedTime 的原帧相位校正只在 fixture 的 `--adaptive-unsynced-spacing` 实验中启用；校正上限 4 ms，`pacingDelay` 为本帧实际采用的 CPU 调度偏移（秒），不是实际显示间隔。此次测试没有建立稳定的性能收益，不默认启用到鸣潮。

可在游戏停止后重复运行自动压测（输出目录需为空或未存在）：

```sh
zsh Scripts/build-app.sh
python3 Scripts/stress-frame-pacing.py \
  --cadence Tests/Fixtures/wuwa-v19-source-cadence.json \
  --surface 3024x1898 --repeats 2 --include-stall \
  --out Artifacts/pacing-next-run
```

脚本按旧→新、新→旧交替，每轮 12 秒，串行运行真实 Metal 捕获、Apple 插帧、呈现和像素读回。`--include-stall` 额外制造 1 秒 Drawable 阻塞，该轮不进入性能中位数。脚本不会启动或结束用户的游戏；超时只停止它创建的测试进程。输出包含逐帧日志、每轮检查结果、完整分析和 summary.json。检查包含当前帧像素、GPU 完成顺序、帧序、重复提交、绝对截止、相位上限、输出尺寸、同步设置及至少 90% 活跃可见的采样。它不模拟游戏绘制负载，不能代替实际战斗验证。

## v22 重构对照

标识为 `pipeline=refactor-v22`。记录与开关入口不变。详见 `presentation-refactor-v22.md`。

在修改或构建新版本之前，保存基线库；随后用 `--baseline-hook` 加载基线和当前 release 做对照。这种模式不会启用相位校正实验：

```sh
cp .build/release/libSwitchViewerGameHook.dylib /tmp/switchviewer-baseline.dylib
# 修改后重新构建
zsh Scripts/build-app.sh
python3 Scripts/stress-frame-pacing.py \
  --cadence Tests/Fixtures/wuwa-v19-source-cadence.json \
  --baseline-hook /tmp/switchviewer-baseline.dylib \
  --repeats 2 --include-stall --out Artifacts/refactor-next-run
```

失败或失去焦点的轮次保留，但从性能中位数剔除。故障注入还检查获取等待期间有源帧产生，以及恢复后一秒继续呈现，不能仅靠进程正常退出判断恢复成功。运行时不要同时启动游戏、其他 GPU 压测或切换前台窗口。

## v23 显示节奏模式

来源 → 游戏 → 显示节奏增加“低时延”和“均匀优先”。默认低时延；均匀优先仅在关闭垂直同步时启用，下一次通过 App 启动游戏生效。游戏运行期间选择器禁用。日志首行记录 `pipeline=cadence-v23 cadence=lowLatency` 或 `cadence=uniform`，便于确认实际加载状态。

均匀优先通过 Metal 的最短显示持续时间减少相邻帧挤在一起，不改变捕获或代理分辨率。`submitted.minimumDuration` 是请求的持续时间，单位为秒，上限 3 ms；只有紧邻上一已提交序号时非零。对应 `drawablePresentCalled.reason=minimumDuration` 的 `requested` 也为持续时间，而非绝对时间戳。该请求不能限制实际新增等待时间，性能取舍见 `frame-cadence-v23.md`。

可用已保存的 v22 库做模式对照，输出目录需为空或未存在：

```sh
python3 Scripts/stress-frame-pacing.py \
  --cadence Tests/Fixtures/wuwa-v19-source-cadence.json \
  --baseline-hook /tmp/sv-cadence-baseline-v22.dylib \
  --candidate-cadence uniform --surface 3024x1898 \
  --repeats 2 --include-stall --out Artifacts/cadence-next-run
```

显式 `--candidate-cadence` 不会附带旧相位实验。报告新增 `cadenceFloorChecksPassed`、覆盖帧数和相对理想半周期的间隔偏差 P95；后者仍不是物理扫描间隔。检查最短持续时间范围、相邻序号和对应 Metal 调用。无游戏绘制负载的回放不能代替正常战斗的帧间隔验证。

短/长间隔判定使用 0.001 ms 容差，避免将刷新节拍附近的微小时间戳误差误判为跨过阈值；原始间隔和 P95 不变。

## v24 已就绪中间帧的准入

均匀优先、关闭同步时，准入改用获取 Drawable（含排队及返回主线程）和编码耗时的滚动 P80，加小量安全余量；不使用提交到呈现的等待。获取完成后的最终检查只保留编码估计及安全余量，不再重复预留获取耗时。仍保留最多 1 ms 的已就绪成对等待、提交前帧序与绝对截止检查、最多两个获取/GPU 任务和最短显示持续时间。旧低时延与同步策略保持原行为。日志 `submitted.reason=unsyncedPreparedPair` 标识新路径；dropped 附带未完成获取、GPU 与呈现回调数。

对照同一模式时，需要明确给基线和新库都设置 uniform，避免将两种模式的差异误判为版本收益：

```sh
python3 Scripts/stress-frame-pacing.py \
  --cadence Artifacts/wuwa-v23-user-oct03-cadence.json \
  --baseline-hook /tmp/sv-uniform-baseline-v23.dylib \
  --baseline-cadence uniform --candidate-cadence uniform \
  --surface 3024x1898 --repeats 3 --include-stall \
  --out Artifacts/prepared-pair-next-run
```

报告新增输出倍率、原帧交付率、中间帧生成率和交付率。交付率排除录制两端各两个已接受输入；中间帧的分母要求前后两个已接受输入都在该范围内。因此它和包含起止瞬态的全窗口 FPS 倍率不严格等价，也不把生成帧数当作显示帧数。对硬件压力和长算法回调，要单独检查 busy、准入丢弃与帧序丢弃；仅放宽准入不能恢复未生成的帧。
