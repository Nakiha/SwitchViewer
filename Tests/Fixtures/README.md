# 调度回归输入

- `wuwa-v19-source-cadence.json`：用户 v19 录制导出的游戏提交间隔，可用于 `Scripts/stress-frame-pacing.py --cadence`。只包含间隔数值和来源说明。
- `unsynced-clustered-presentations.json`：同轮记录的一段帧序号/呈现时间，时间已平移；用于检测呈现聚簇的控制器回归测试。

这些输入不包含图像或账号信息。输入节奏回放不能重现鸣潮自身的 GPU 绘制负载；时间序列测试也不能预测系统收到新提交之后的实际呈现结果。
