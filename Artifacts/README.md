# 插帧验证资料

这里保存实验结论与验证流程。大型原始日志、逐帧分析 JSON、录像、测试 App 和图像读回留在本地，不作为版本控制内容。可重复使用的数值输入放在 `Tests/Fixtures/`。

仓库于 2026-10-05 清理并重建历史。报告中的历史日志路径与实验编号仅用于解释当时的测量，原始产物不随源码分发；部分早期界面和测试数量描述不代表当前版本。当前构建与测试入口见根目录 README。

## 当前入口

- `prepared-pair-v24.md`：均匀优先的 CPU 准入预算修正与最新鸣潮节奏回放对照。
- `game-injection.md`：游戏内插帧的接入与使用。
- `frame-trace-workflow.md`：30 秒记录、逐帧分析、Metal 节奏回放和自动压力测试。
- `frame-cadence-v23.md`：低时延与均匀优先模式、帧间隔改善及其显示等待代价。
- `presentation-refactor-v22.md`：呈现策略、提交任务和 Drawable 资源管理的职责边界与重构验证。
- `frame-pacing-v21-review.md`：前一轮帧间隔实验和未启用方案的原因。
- `unsynced-submission-v19.md`：当前正式无同步提交策略。

## 定位过程

- `early-capture-v12.md`、`midpoint-admission-v13.md`：提前捕获和中间帧接纳。
- `latency-overlap-v14.md`、`frame-submission-v15.md`：原帧提前准备与成对提交。
- `latency-profile-v16.md`：插帧代理分辨率档位。
- `presentation-localization-v17.md`、`presentation-clock-v18.md`：呈现阶段与时钟诊断。
- `wuwa-v*-review.md`：各轮实际鸣潮记录的结论。

正确性检查通过只代表帧顺序、像素和提交边界满足检查，不代表帧间隔均匀或已经消除卡顿。判断策略收益应同时检查原帧年龄、短/长呈现间隔、有效中间帧比例与窗口可见性。
