# v18 呈现等待关联埋点

新增仅在录制期间运行的 Core Video 显示时钟观察器。它绑定游戏所在屏幕、随屏幕变化重建、录制结束停止；不获取 drawable、不修改 CAMetalLayer、不驱动提交。没有采用此前会改变呈现协议的 CAMetalDisplayLink。

每个 displayTick 包含录制时的 callback 时间、Core Video now/output host timestamp 换算的时间、有效的 nominal refreshPeriod 和 displayID。output 时间是系统预测目标，不是物理扫描或真实 VRR 的证明。来源：[Apple CVDisplayLink](https://developer.apple.com/documentation/corevideo/cvdisplaylink-k0k)、[CVTimeStamp](https://developer.apple.com/documentation/CoreVideo/CVTimeStamp)。旧 Core Video API 已弃用，此处用于独立诊断时钟，避免将输出层绑定到另一种调度协议。

schema=3 新增字段均可选，兼容已有记录。提交与呈现记录 drawableID，可用于后续系统 Trace 关联。分析器按同一帧关联：

- GPU 完成后第一个预测显示节拍距离。
- presentedTime 相对该预测节拍的间隔，以及期间预测节拍数。
- 实际呈现请求方法、请求时间相对 GPU 完成的间隔。
- 呈现调用时，先前已请求且尚未呈现的已确认帧数，以及按原帧/中间帧和这个数量分组的 GPU 完成后等待。

队列数由历史请求和 presentedTime 重建，仅计有确认的帧，是下界；不是主线程 pendingPresentation 回调计数，也不是 WindowServer 队列深度。没有跨屏变化或完整节拍覆盖的帧不填节拍关联；不会补造缺失的观测。GPU 完成后跨过预测节拍不等于确定错过了物理刷新。

## 本地验证

真实 Metal/Apple 清晰档 1080p、垂直同步关闭、鸣潮 v15 原帧间隔回放，12 秒 fixture：

- 1,447 个预测节拍，523 个原帧中 518 个关联成功。
- GPU 完成后跨 0/1/2/3/4/5 个预测节拍：52/244/152/61/8/1 帧；5 帧录制边界不匹配。
- 前方已确认等待帧 0/1/2：129/354/40 帧，对应原帧 GPU 后等待 P50 9.55/10.91/18.44 ms。
- 输出 81.49 fps，原帧总时延 P50 33.33 ms，GPU 后等待 P50 10.86 ms。不能将此次回放当作真实鸣潮实测或严格同负载 A/B。
- 531 个像素与 GPU 顺序检查通过，966 帧完整阶段；呈现顺序错误 0，埋点溢出 0。
- 分析器 9 个测试、GameFrameTrace 2 个测试通过；构建、签名和 diff 空白检查通过。

等待帧较多时尾部较长，支持继续调查排队压力的方向，但不证明排队就是唯一原因；前方无已确认等待帧时仍有约 9.55 ms 等待。下一轮实际鸣潮使用相同录制按钮/快捷键，无需新操作。新 dylib 需要下次通过 App 启动游戏加载，正在运行的游戏不会被更新 bundle 自动替换。

输出分析：[v18-presentation-clock.json](v18-presentation-clock.json)。原始测试日志 /tmp/sv-v18-cadence.log。
