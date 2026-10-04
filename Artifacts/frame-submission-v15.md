# v15 成对提交仲裁

以鸣潮 v14 的 30 秒记录为依据。v14 约 44.02 fps 输入、84.91 fps 显示；41 个中间帧被帧序保护丢弃，其中 10 个在后续原帧提交前已生成。只放宽截止时间无法解决两个独立提交回调争抢顺序的问题。

## 实现

- 主线程发布已就绪中间帧的提交动作，按序号原子取走。正常计时器和后续原帧的主动调度共同使用这一入口，同一中间帧只能提交一次。
- 后续原帧提交前先推动已准备好的前一中间帧。中间帧获取 Drawable 时仍保有优先位置，直到提交、放弃或超出有界窗口。
- 尚未算完的中间帧只能让原帧等到旧提交时刻；已经算完的中间帧最多获得旧提交时刻之后 1 ms，且不能超过原帧绝对过期时间。超过预算继续提交原帧，晚中间帧依然不能覆盖它。
- 中间帧提交或放弃后异步唤醒原帧，避免 0.5 ms 轮询。唤醒安排到当前中间帧提交回调结束之后，防止递归提交导致原帧先 commit。
- epoch 切换会清理全部就绪动作和等待动作，避免跨窗口/原画面切换后继续执行旧任务。修补中间帧编码失败时未释放仲裁位置的路径。
- 现有绝对过期、容量、GPU 顺序、源帧复制、呈现顺序和看门狗保护保留。没有取消垂直同步，也没有重新启用 CAMetalDisplayLink。

主要文件：GameFrameSubmissionArbiter.swift、GameHook.swift。版本标识 adaptive-v15。测试窗口专用 --legacy-pair-submission 关闭就绪中间帧主动调度和额外 1 ms 所有权，用同一二进制做策略对照；它不是恢复整个旧版本。

## 回放与限度

使用 wuwa-v14-user-latest-cadence.json 的真实源帧间隔，执行实际 Apple 算法、GPU 复制/回读以及 Metal 呈现，而非只模拟计时器。12 秒回放覆盖启动阶段，和实际鸣潮战斗负载不同。

| 回放 | 输出 fps | 原帧 P50 ms | 原帧 P95 ms | 帧序丢弃 |
| --- | ---: | ---: | ---: | ---: |
| 同二进制控制 | 82.15 | 43.84 | 49.08 | 40 |
| 成对调度首轮 | 82.77 | 42.86 | 49.11 | 35 |
| 首轮策略重复 | 81.92 | 44.07 | 49.66 | 42 |
| 最终事件唤醒策略 | 82.40 | 43.09 | 48.48 | 29 |

最终回放：529 个输入，527 个正确像素及 GPU 写入顺序样本，497 个原帧有提前预算，208 次有界等待，24 次中间帧先解决后原帧在预算内提交。无重复提交、无过期提交、无帧序倒退、无记录溢出、无 >=60 ms 的整体呈现空档。仍有 30 次截止丢弃，不能声称已经消除中间帧损失或稳定达到 2×。

首轮配对策略启动期曾有 108 ms 显示空洞；最终正常回放未重现，不能据此认定永久解决。回放差异证明改动的收益目前较小且有波动，实际鸣潮 v15 收益待验证。

42 项 Swift 测试与 7 项 Python 测试通过。新增仲裁测试覆盖未完成任务不能延长窗口、已就绪/获取中任务的 1 ms 上限、绝对期限、无关序号和重置。逐帧检查同时验证唯一提交、绝对过期与所有权窗口。

## 再现

```sh
env DYLD_INSERT_LIBRARIES="$PWD/.build/release/libSwitchViewerGameHook.dylib" SWITCHVIEWER_GAME_HOOK=1 SWITCHVIEWER_FRAME_TRACE=1 .build/release/GameHookFixture --cadence="$PWD/Artifacts/wuwa-v14-user-latest-cadence.json" --direct-presentation --direct-in-flight --validate-copy --smoke-test
python3 Scripts/check-early-capture.py /tmp/switchviewer-v15-final.log --expect-route directAfterGPU --validate-copy --check-midpoint-gate --minimum-advanced-originals 100
```

最终压力验证使用常规 commandBuffer 路径、30 fps、4–8 秒插帧回调额外延迟、每两秒尺寸变化以及一次人工 1 秒 Drawable 获取阻塞。359 个输入、358 个正确像素样本，零重复提交、零过期提交、零帧序倒退、零记录丢失。人为阻塞加看门狗重试产生 1.875 秒显示空档，之后恢复；记录器保留该异常，没有用平滑统计遮蔽。压力下输出约 42.8 fps、原帧 P50 53.8 ms，不能与正常回放作性能对照。

发布：`Scripts/build-app.sh` 完成，根目录 SwitchViewer.app 已更新，deep/strict 签名校验与 diff 空白检查通过。未停止或重启用户正在运行的鸣潮。
