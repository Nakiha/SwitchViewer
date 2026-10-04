# 游戏内 Apple 插帧实验

欢迎界面的“游戏内插帧（实验）”打开独立启动面板，可以启动鸣潮、选择其他 Mac app，或打开 30fps 的测试窗口。此模式需要 macOS 26 或更新版本，目前构建为 ARM64。

## 接入方式

- 启动目标的主程序时，通过 `DYLD_INSERT_LIBRARIES` 加载 `libSwitchViewerGameHook.dylib`。不改目标文件、不重新签名、不关闭系统保护；目标不允许加载时会显示未确认成功。
- 在进程初始化阶段安装 Metal 呈现方法拦截，避免 Unreal/mtlpp 提前缓存原始 IMP。覆盖 command buffer 和 drawable 的普通、指定时间、最短间隔呈现方法。
- command buffer 路径在原命令缓冲末尾复制纹理，GPU 完成后再处理。直接 drawable 呈现路径等待其 presented 回调，在独立 GPU 队列复制已完成的纹理。因此这条路径仍包含原帧首次显示的等待。
- 将 SDR BGRA 纹理用 Metal 数值矩阵转为 NV12，再调用项目已有的 `AppleDownsampledFrameInterpolator`。原帧保留原尺寸，中间帧在最高 1080p 代理上生成。显示解码不额外转换 gamma/色域，显示 layer 继承游戏自身的 colorspace（包括 nil）；sRGB 纹理通过原始 UNORM view 读取，避免 GPU 自动线性化。
- 在游戏原 Metal layer 上加一个子 layer 呈现延迟后的原帧和中间帧。输入仍交给游戏窗口；原游戏的绘制与呈现继续执行。此原型不是引擎级运动矢量插帧，也没有省去原游戏的呈现成本。
- 每次仅保留一个处理任务，播放调度不允许积压到两个输入帧间隔以上；过期显示任务丢弃。错误或超过 0.5 秒没有新处理结果时隐藏子 layer，露出游戏原画面。
- 游戏重建 layer 层级后会重新挂接显示子 layer；超过 1 秒没有实际上屏回调时，隐藏插帧画面并退避重试。窗口切换过程中不能保证持续插帧，面板显示以实际上屏回调为准。
- 接入日志使用继承的普通文件描述符，保存在 `~/Library/Logs/SwitchViewer/GameInjection/`，避免启动器退出时关闭管道触发游戏 SIGPIPE。退出启动器不会主动结束游戏；退出游戏后此次加载结束。
- 游戏内按 `⌥⇧I` 可在原游戏画面和插帧画面之间切换，用于颜色和画质对照；暂停时停止捕获和插帧。

## 构建与验证

执行 `Scripts/build-app.sh`，会构建并更新 `SwitchViewer.app`，包含动态库和测试程序，并验证应用签名。

测试程序支持以下组合：

```sh
SWITCHVIEWER_GAME_HOOK=1 \
DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" \
.build/release/GameHookFixture --smoke-test

SWITCHVIEWER_GAME_HOOK=1 \
DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" \
.build/release/GameHookFixture --smoke-test --direct-presentation --resize-test
```

`--smoke-test` 在 12 秒后退出。普通测试覆盖三种 command buffer 呈现方法；直接呈现测试覆盖三种 drawable 方法，并在运行中进行 1080p → 720p → 1080p 切换。`DISPLAY` 指标来自 `MTLDrawable.presentedTime` 回调，不只是生成帧计数；它不能测量面板扫描或鼠标操作到显示的完整延迟。

## 当前限制

目标为 2× 输出，实际吞吐取决于游戏与插帧竞争 GPU 的负载，不能保证源帧率不下降。仅 SDR BGRA8、大于等于 1024×576 的单个主画面 layer；HDR、多视口和 Metal 4 的其他提交接口未验证。高分辨率生成帧存在代理缩放的细节软化。联网游戏的官方允许范围、保护机制及长期兼容性仍需单独确认。

## 2026-10-01 验证结果

- 本机 macOS 27、Apple M5：release 构建及应用严格签名验证通过；现有 4 个自动测试全部通过。
- 普通测试窗口 30fps 输入，暖机后 `DISPLAY` 约 59–60fps。直接 drawable 呈现与 1080p → 720p → 1080p 切换测试完成，无崩溃，窗口输出统计约 54–58fps。
- 本机鸣潮 3.7.0（原签名、沙盒保留）确认成功加载动态库。Unreal 路径需在 main 之前安装拦截，并覆盖直接 drawable 呈现；仅拦截 command buffer 呈现不足。
- 鸣潮原纹理为 3024×1898、BGRA8 SDR；Apple 插帧使用 1920×1080 代理。截图检查发现并修复了上下颠倒，最终实际游戏画面的方向和文字正常。
- 启动画面期间呈现统计约 75–78fps，实际游戏场景的一轮统计约 89fps，Apple 插帧回调耗时约 11–14ms。这些是当时场景和负载下的输出数据，不是严格控制条件的性能对比，不证明稳定 2× 或更低输入延迟。
- 最终游戏进程仍在运行，便于用户继续体验；退出 SwitchViewer 不会因诊断输出管道断开而结束游戏。

## 色彩回归修复

用户指出新模式复现了色彩变淡。查阅此前 chat `01a0f21f-f315-7b71-8e78-bcd635710e7a`：旧修复针对 ScreenCaptureKit 默认颜色空间与 sRGB 显示之间的不一致；本次新增的 Core Image 转换并不经过该捕获路径。

独立灰阶对照复现新模式的转换偏差：RGB 16→14、32→35、64→73、128→139。旧转换先按 sRGB 输入，再给 NV12 设置 Rec.709 transfer，随后按这些附件进行显示转换；还把原游戏的显示层强制标成 sRGB。

修复删除该 Core Image 往返，采用不改 gamma/色域的 Metal RGB↔NV12 矩阵，并继承原游戏 layer 的 colorspace。颜色测试覆盖黑白、暗灰、饱和色、纹理上下方向、UNORM 与 sRGB 纹理、Apple 对相同帧生成中间帧。RGB 往返每通道误差不超过 2/255；Apple 静态灰阶中间帧每通道误差不超过 3/255，两项测试通过。这些测试验证数值链路，不能替代具体显示器与真实运动画面的观感验收。

最终 release 全量 6 个测试通过，应用重新构建并签名。修复版鸣潮实际游戏场景确认 `COLOR sourceSpace=unmanaged encodedRGBPassthrough=true`，输出回调约 89fps；⌥⇧I 原画面/插帧切换产生对应 PAUSED/RESUMED 日志。游戏场景在对照过程中有移动，截图未用于逐像素比较。最终恢复插帧运行，用户可用该快捷键在固定视角下继续对照。

## 2026-10-01：卡顿埋点（LAG 倒带）

用户反馈"只有插帧时偶发一两百毫秒的大卡顿，卡住整个画面"。现有日志只有 1 秒粒度的 P50 和看门狗报错，单帧尖峰会被中位数吃掉；显示调度里十几条 return 路径完全静默。本次补齐埋点，便于下一次复现时直接定位。

### 新增日志

- 每条 hook 行现在带本地墙钟和单调时间：`[SwitchViewerHook 23:30:46.568 +    8.232]`，可以直接和游戏自身 stderr 行对齐。
- `TRACE` 每秒一条，不依赖上屏回调，所以显示路径整体挂掉时日志不再静默：
  `TRACE window=1.03s sched=59 submit=55 present=52 pending=7 capGapMax=66.6ms capGaps=0 gapMax=133.3ms gaps=1 ageMax=124.6ms tgtErrMax=24.0ms s2pMax=32.5ms | capSkipBusy=1 dropStaleSeq=4 presentTime0=3`
  - `sched/submit/present` 是"尝试提交 / 已提交 / 已确认上屏"的窗口计数；
  - `pending` 是已提交但没拿到确认的 drawable 数，持续大于 0 就是"提交了没上屏"；
  - `capGapMax` 是采集间隔最大值，用来区分"游戏侧停顿"和"我们显示路径停顿"；
  - `gapMax/ageMax/tgtErrMax/s2pMax` 是最大值，补上原来只有 P50 的盲区；
  - 竖线后是窗口内非零的丢弃原因计数。
- `LAG` 在三种停顿下倒带逐帧事件，每种独立限流、互不压制：
  - `captureGap`：相邻两次采集 > 80ms，说明游戏侧（或我们的 busy 窗口）停住了；
  - `presentationGap`：相邻两次上屏 > 60ms，说明显示路径漏了帧；
  - `noPresentation`：看门狗探针发现 > 500ms 完全没有上屏回调。前两种都要等"下一次"
    才能算出间隔，显示路径彻底停摆时等不到，只能靠探针——那正是几分钟中断的形状。
  倒带内容是停顿前的上下文、停顿刚开始的 60 条、以及恢复前的 25 条；中间用"省略 N 条"折叠，
  否则一次几分钟的中断会倒带上万行。同一轮停顿最多倒带 3 次，恢复一次正常间隔后重新计数。

### 覆盖的静默路径

采集跳过（busy / 暂停 / 其他 layer / 纹理失败 / GPU 失败）、几何重建、
RGB→NV12 失败、插帧提交/完成/失败/忙跳过、以及显示调度的全部丢弃原因：
`dropPaused`、`dropStaleEpoch`、`dropNotReady`、`dropStaleSeq`、`dropExpired`、
`dropRetryWait`、`dropLate`、`dropNoResource`、`dropNoSlot`、`dropNoDrawable`、
`dropNoCmdBuf`、`dropEncodeFail`、`dropPastExpiry`，加上 `presentTime0`
（`presentedTime == 0`，提交了但系统没确认上屏）和看门狗的两种隐藏原因。

### 验证

`FrameStallTrace` 有 11 个单元测试（环形缓冲、倒带范围、轮次限流、窗口增量计数、
pending 统计、静默探针）。测试程序新增 `--stall-test`：每 3 秒阻塞主线程 220ms，模拟游戏主线程停顿。

- `Artifacts/game-hook-trace-stall.log`：每次停顿同时产出两条独立倒带——
  `LAG kind=captureGap gap≈221ms` 和 `LAG kind=presentationGap gap≈233ms`，各 25–31 行；
  同一窗口的 `TRACE` 报出 `capGapMax=221.3ms capGaps=1 gapMax=233.3ms gaps=1`。
  未加限流前同样的 12 秒会产生 1024 行/次的转储，收敛后整份日志 250 行。
- `Artifacts/game-hook-trace-resize.log`：几何切换时抓到 `LAG kind=presentationGap gap=133.3ms`，
  倒带把因果链写全了：旧 layer 两帧 `presentedTime=0` → 采集 52.5ms 间隔 →
  `BUILD 1280x720->1920x1080 itp=54.6ms` → `SHOW` 后首帧仍 `presentedTime=0` →
  133ms 后才上屏，且那一帧的内容已经 124.6ms 旧。
  早期观察到的 `pending` 上涨其实是 `presentTime0`（回调到了、只是没上屏）；把这两者分开统计后，
  层重建并不泄漏 drawable。
- release 构建、应用签名验证通过；全量 30 个测试通过。

## 2026-10-02：几何变化重建路径修复

埋点把 100–133ms 的停顿稳定复现出来了，根因是**每次 drawable 尺寸变化都重建整条显示链**：

- `AppleDownsampledFrameInterpolator` 重建 = 重造缩放器 + 重启 VideoToolbox 会话，本机实测 42–59ms；
  而 3024×1898 与 3024×1764 用的是同一个 1920×1080 代理，会话本身没变。
- `configureOverlay` 每次删除并新建 `CAMetalLayer`：切换瞬间旧 layer 的呈现拿不到确认，
  新 layer 的首帧同样返回 `presentedTime == 0`，两次未确认叠在重建耗时上就是那 100ms。
- 另外，`schedule()` 只在 commit 成功之后才取消隐藏，而隐藏状态的层可能拿不到
  `nextDrawable` —— 一旦被看门狗隐藏就走不到取消隐藏那一行，只能等下一次几何变化重建 layer
  才能脱身。这与日志里"几分钟的中断只在 `READY` 处结束"吻合。

三处修改：

1. `AppleDownsampledFrameInterpolator.reconfigure(width:height:)`：代理档位不变时就地改写输入尺寸，
   复用已经启动的会话与缩放器。
2. `configureOverlay` 复用同一个 `CAMetalLayer`，只更新 `frame`/`drawableSize`/`colorspace`。
3. `schedule()` 先取消隐藏再取 drawable，取不到就立刻恢复隐藏，避免露出旧画面。

### A/B 验证（`--resize-storm`：每 2 秒切换一次 drawable 尺寸，两个尺寸映射到同一个 1080p 代理）

`Artifacts/game-hook-trace-resize-storm-before.log` / `-after.log`，各 5 次切换：

| 指标 | 修复前 | 修复后 |
|---|---:|---:|
| 单次重建耗时 | 42.8–55.4ms | 0.9–1.3ms（首次新建会话 58ms） |
| `LAG` 停顿次数 | 3 | 0 |
| 上屏间隔最大值 | 100–108ms（超阈值） | ≤50ms |
| 每窗口 `presentTime0` | 2 | 1 |

修复前的倒带显示停顿构成：旧 layer 末帧 `presentedTime=0` → 切尺寸 →
`BUILD itp=50.1ms` → `SHOW` 后首帧仍 `presentedTime=0` → 100ms 后才上屏，
那一帧内容已经 122.1ms 旧。

### 复现方式

```sh
SWITCHVIEWER_GAME_HOOK=1 \
DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" \
.build/release/GameHookFixture --smoke-test --stall-test

SWITCHVIEWER_GAME_HOOK=1 \
DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" \
.build/release/GameHookFixture --smoke-test --direct-presentation --resize-test

SWITCHVIEWER_GAME_HOOK=1 \
DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" \
.build/release/GameHookFixture --smoke-test --resize-storm
```

游戏内复现需要重启游戏进程才能加载新动态库；日志仍在
`~/Library/Logs/SwitchViewer/GameInjection/`。排查顺序：先看 `TRACE` 行的
`capGapMax`（游戏侧停顿）、`present` 掉到 0（显示路径停顿）、`pending`（完全没有回调的提交），
再看 `LAG` 倒带里停顿前最后几条事件和 `BUILD` 的 `conv/itp/overlay` 耗时。
