# 多倍率低时延插帧实验 · 2026-10-05

结论：Apple M5 上，30 fps 输入时，720p 代理 4× 是最值得接入的候选；1080p 4× 的持续吞吐和呈现余量均偏紧。当前系统仍是原帧/中间帧两槽结构，实验没有把生产 App 改成多倍率，也没有测量游戏内的最终屏幕时延。

## 方法

- Apple M5，macOS 27，本机显示能力查询为最高 120 Hz。
- 使用用户实际录制的鸣潮原始素材，以及 Switch 原始素材；都是 1920×1080 NV12 解码输入。Switch 原始轨为 60 fps 采集，隔一帧取样，按约 30 fps 内容进行帧对测试。取两个录制的开头约 3.3 秒，不能代表所有游戏场景。
- 每种配置预热 8 对，统计 90 对。分别测 1080p 和 720p、2×/4×/8×、整批完成回调及逐帧 AsyncSequence。
- 从输出分配/参数构建开始计时，记录每个指定相位的实际回调就绪时间及整批完成时间。每张输出都检查非空亮度；没有把成功初始化当作实际处理成功。
- 解码和 720p 输入缩放预先完成，不计入表中；输入缩放本轮独立中位数约 0.52 ms。未计游戏纹理转换、输出放大、游戏自身 GPU 竞争、drawable 获取或 WindowServer 显示等待。
- 配置深度 1/2/3 对应相位网格；实际 2×/4×/8× 分别请求 1/3/7 张输出。另测深度 2 只请求 0.5，相比深度 1 单帧没有明显额外耗时；仅改变配置数字不代表真的生成了多帧。
- 所有数据均来自执行 Apple API，实验中各配置均成功生成要求数量的输出。

## 实测结果

下表使用逐帧返回模式；范围是鸣潮 / Switch 两段素材各自统计值的最小值至最大值，不是置信区间。

| 处理尺寸 | 倍率 | 整批完成 P50 | 整批完成 P95 | 最早时间相位就绪 P50 |
|---|---|---|---|---|
| 1920×1080 | 2× | 10.32–10.33 ms | 10.67–10.76 ms | 10.31–10.32 ms |
| 1920×1080 | 4× | 30.84–31.28 ms | 31.34–33.46 ms | 20.57–20.84 ms |
| 1920×1080 | 8× | 72.08–72.29 ms | 73.01–73.09 ms | 31.08–31.09 ms |
| 1280×720 | 2× | 3.72–3.77 ms | 3.94–3.95 ms | 3.72–3.75 ms |
| 1280×720 | 4× | 11.06–11.17 ms | 11.58–11.60 ms | 7.41–7.48 ms |
| 1280×720 | 8× | 25.70–25.97 ms | 26.19–26.58 ms | 11.14–11.30 ms |

4× 逐帧返回让第一张 0.25 相位帧比整批完成提前约 10 ms（1080p）或 3.6 ms（720p），整批总工作量基本不变。8× 的回调就绪并非等时间间隔：1080p 的 0.125/0.25 相位约 31 ms，0.375/0.5 约 41 ms，0.625/0.75 约 62 ms，最后一张约 72 ms。因此不能把多个输出一收到就连续呈现。

## 代入当前呈现策略

用真实 `GameFramePressureController` 求当前 2× 稳态原帧延迟，用 `GameFramePresentationPolicy.initialRejection` 检查每个生成帧的独立槽位。假设空输出队列、均匀输入、额外转换/派发耗时 2 ms；另保存 8 ms 开销的敏感性回放。逐帧模式使用每个相位的实测就绪时间，整批模式使用整批回调就绪时间。

30 fps 时，当前控制器在这组纯插帧测量下收敛到约 34.33 ms 原帧缓冲。这是模拟值，不能替代 App 中的总时延。新的最小缓冲按 `max((1-phase)*输入间隔 + 就绪耗时 + 假定管线开销 + 当前准备余量)` 逐对求值，再取 P95；它要求各帧能在其目标时间前提交，强于“截止前抢救出来”。

| 逐帧模式，30 fps 输入 | P95 所需原帧缓冲（估算） | 相比当前 2× 额外缓冲（估算） | 当前缓冲下槽位准入率 |
|---|---|---|---|
| 1080p 4× | 51.88–53.40 ms | +17.55–19.06 ms | 0% |
| 1080p 8× | 82.91–82.99 ms | +48.58–48.66 ms | 0% |
| 720p 4× | 38.46–38.56 ms | +4.12–4.23 ms | 100%，但首张晚于目标，节奏不均匀 |
| 720p 8× | 46.49–46.68 ms | +12.15–12.35 ms | 42.9% |

**准入率是无 GPU 排队的离线策略回放，不是实机呈现率。** 1080p 4× 的整批处理加假定 2 ms 开销，只有约 54%–93% 的作业能落在 30 fps 的 33.3 ms 输入周期内；即便延长显示缓冲，也不能解决持续吞吐不足。720p 4× 在此轻载实验里吞吐有较多余量。

当前 120 Hz 屏幕适合 30→120 fps 的 4×；30 fps 的 8× 请求的是 240 fps，当前屏幕无法显示全部帧。720p 8× 虽然算法吞吐可以满足这组 30 fps 输入，仍不应据此宣称本机显示出了 240 fps。

60 fps 的回放数据仅是时间预算算术：当前预排队路径仅支持输入 ≤50 fps，高帧率使用其他路径；报告不把这些行算成既有呈现系统的验证结果。

## 接入需要改什么

可以复用原有输入转换、Apple processor、drawable 池与呈现反馈，但不能只改配置数字：

1. 将单个 `Result.pixelBuffer` 扩成带相位/源内容时间戳的多输出回调，并保持 Apple 输出只读。
2. `pairSequence * 2`、唯一 pending midpoint、下一原帧只等待 `sequence-1` 等两槽约定，需推广成 N 槽组和按相位排序的所有权。
3. 每张生成帧单独定义目标与到期时间，不能沿用整段“到下一原帧之前都可显示”的宽到期范围。
4. 缓冲控制器必须考虑最早相位就绪时间和输入等待时间；不能只拿整批处理耗时预测中点预算。
5. 多帧返回、原帧预排队和 drawable 背压共同限制待显示数量；录制也需把 `interval/2` 改为实际 phase。
6. 在游戏并行负载下测实际 presentedTime、各相位呈现比例、P95 总时延、相邻显示间隔，再决定是否开放 4×。

下一步建议：先在 fixture 中接 720p 4× 的逐帧输出，以约 39 ms 的初始原帧缓冲做实验起点；若实际转换/绘制开销接近 8 ms，所需缓冲还会增加。保持正式模式 2×，直到实机 presentedTime 验收。

## 复现

```sh
swift build -c release --product FrameInterpolationLab
.build/release/FrameInterpolationLab --multiframe-probe=/path/to/original.mov --multiframe-output=Artifacts/multiframe-probe.json --multiframe-samples=90
# 60 fps 的 Switch 采集轨需要再加 --multiframe-stride=2
.build/release/FrameInterpolationLab --multiframe-replay=Artifacts/multiframe-probe.json --multiframe-output=Artifacts/multiframe-replay.json
python3 Scripts/summarize-multiframe-probe.py Artifacts/multiframe-probe.json
```

本机原始测量保留在 `Artifacts/multiframe-wuwa-20261005.json`、`Artifacts/multiframe-switch-20261005.json`，呈现回放分别为 `*-playout-20261005.json`。JSON 含逐对/逐相位数据，按仓库规则不提交；本报告和复现实验工具提交。

API 依据：[低时延插帧配置](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration/init(framewidth:frameheight:numberofinterpolatedframes:))、[逐帧输出接口](https://developer.apple.com/documentation/videotoolbox/vtframeprocessor/processwithparameters:frameoutputhandler:?language=objc)。
