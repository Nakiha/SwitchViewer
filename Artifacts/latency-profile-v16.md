# v16 低时延档及呈现路径实验

## 结果

本轮没有验证出通过替换呈现 API/层级即可少一个刷新周期的方案。找到的有效方向是缩短前一对插帧的计算：游戏低时延档使用最高 1280×720 的 Apple 中间帧代理，而原帧仍以捕获分辨率显示。

来源 → 游戏新增“插帧偏好”：清晰优先 / 低时延（最高 720p）。默认保持清晰优先；偏好保存到 UserDefaults，经游戏启动环境传给 hook。游戏运行时控件禁用，下次启动生效。明确代价是中间帧更软、细节与运动边缘可能变化，并非免费画质优化。没有降低游戏自身渲染或原帧分辨率。

## 实际 GPU 回放

使用鸣潮 v15 用户记录导出的源帧间隔，执行实际 Apple 插帧、GPU 复制/回读以及 Metal 呈现；每轮 12 秒。不同轮次并非严格相同 GPU 负载 A/B，收益不等于真实鸣潮的新版本验证。

| 试验 | 输出 fps | 原帧 P50 / P95 ms | 原帧提交→显示 P50 ms |
| --- | ---: | ---: | ---: |
| 清晰档控制 | 83.36 | 43.45 / 48.25 | 23.87 |
| 覆盖层改为同级 | 83.25 | 43.75 / 48.32 | 23.85 |
| GPU 完成后直接呈现 | 83.77 | 43.12 / 48.82 | 23.84 |
| 事务同步呈现 | 83.34 | 43.94 / 49.16 | 23.94 |
| 三个 Drawable | 83.31 | 42.93 / 48.23 | 26.89 |
| 720p 首轮 | 85.11 | 36.18 / 43.84 | 24.04 |
| v16 环境偏好再次验证 | 85.47 | 39.79 / 44.89 | 23.96 |

同级图层和直接呈现没有稳定缩短尾部。增加 Drawable 将更早的提交换成更长的呈现等待。事务试验按 GPU 完成后在主线程事务内调用 drawable.present 的方式执行，没有错误地混用 commandBuffer.present；[Apple 的事务呈现要求](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)。这些试验及开关已从正式源代码移除，保留分析 JSON 作为证据。

720p 首轮 Apple 处理 P50 6.43 ms，正式偏好重复轮 8.30 ms，而本轮先前实际鸣潮 v15 是 11.30 ms。原帧 P50 回放观察到约 3.7–7.3 ms 改善，尾部仍约 24 ms，没有验证出平台呈现等待减少一帧。不能承诺实际鸣潮稳定达到 36 ms，也不能把不同负载的结果当作精确性能预测。

## 验证

- 44 项 Swift 测试、7 项 Python 分析器测试通过。新增覆盖代理分辨率上限、大输入、不能放大小输入、不支持输入及清晰档既有尺寸选择。
- v16 正式偏好经 SWITCHVIEWER_GAME_PROFILE=lowLatency 验证：日志为 adaptive-v16，INTERPOLATION_PROXY 1280×720；533 次直接 GPU 路径、531 个正确像素及 GPU 顺序样本；零帧序倒退、重复提交、绝对期限越界与记录溢出。正常最终回放无 >=60 ms 显示空洞。
- 常规 commandBuffer 路径叠加 30 fps、插帧处理延迟、反复尺寸变化、人工 1 秒 Drawable 获取阻塞：359 个输入、358 个正确像素样本，零帧序/重复/期限错误。代理会话在尺寸变化后持续保持 1280×720；人工停顿造成 1.075 秒空洞后恢复。压力负载的 40.74 ms P50 不能与正常回放当作 A/B。
- 源帧代理设置影响 AppleDownsampledFrameInterpolator 的配置选择与 reconfigure，尺寸变化不会意外恢复 1080p。非法启动偏好回退清晰档。
- Scripts/build-app.sh、deep/strict 签名校验和 diff 空白检查通过。未停止用户鸣潮或将未验证的呈现试验注入游戏。

## 再现

```sh
env DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" SWITCHVIEWER_GAME_HOOK=1 SWITCHVIEWER_FRAME_TRACE=1 SWITCHVIEWER_GAME_PROFILE=lowLatency .build/release/GameHookFixture --cadence="$PWD/Artifacts/wuwa-v15-user-latest-cadence.json" --direct-presentation --direct-in-flight --validate-copy --smoke-test
python3 Scripts/check-early-capture.py /tmp/sv-v16-lowlatency.log --expect-route directAfterGPU --validate-copy --check-midpoint-gate --minimum-advanced-originals 100
```

核心修改：GameInterpolationProfile.swift、AppleDownsampledFrameInterpolator.swift、GameHook.swift、GameInjectionController.swift、ViewerSettingsView.swift。
