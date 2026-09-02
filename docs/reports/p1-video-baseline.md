# P1 真机首帧与视频性能基线

## 结论

- [x] Flutter Widget 显示方向、比例和内容正确的真机首帧。
- [x] 原生 Media Foundation 解码并通过 Flutter Texture 显示。
- [x] 记录连接、解码器就绪和首帧耗时。
- [x] 记录实际分辨率、FPS、码率、CPU、GPU和内存基线。
- [x] 连续 30 秒采样期间无视频错误。

P1-02 验收通过。

## 环境

- 日期：2026-09-02
- 宿主：Windows Debug
- 设备：Xiaomi 23127PN0CC，Android 16
- scrcpy server：4.1（插件内置）
- 视频参数：H.264、最大 1920 px、60 FPS、8 Mbps
- 视频后端：Windows Media Foundation + Flutter Texture
- 采样时间：30 秒

设备序列号未写入报告。

## 结果

| 指标 | 第一次运行 | GPU 同步采样运行 |
|---|---:|---:|
| ADB/server/视频连接 | 658 ms | 644 ms |
| 解码器就绪 | 928 ms | 916 ms |
| Flutter 首帧 | 1259 ms | 1223 ms |
| 解码尺寸 | 862×1920 | 862×1920 |
| 实际显示 FPS | 4.75 | 9.94 |
| 接收码率 | 0.15 Mbps | 8.98 Mbps |
| 归一化 CPU | 3.58% | 10.76% |
| GPU 平均/峰值 | 未采样 | 2.88% / 3.91% |
| 工作集 | 468.16 MiB | 462.69 MiB |
| 私有内存 | 444.48 MiB | 450.24 MiB |

第一次运行期间设备画面较静态，scrcpy 按内容降低了实际帧和码率；第二次运行与 Windows GPU Engine 性能计数器同步采样，设备内容活动更高，因此作为主要性能基线。

## 采集方式

- `example/integration_test/video_baseline_test.dart`：采集连接阶段耗时、原生 `videoStats`、30 秒帧数、输入包、进程累计 CPU 时间、工作集和私有内存。
- Windows 插件 `processMetrics`：使用 `GetProcessTimes` 与 `GetProcessMemoryInfo`，避免从 Dart 逐帧路径推断原生开销。
- GPU：按 Demo 进程 PID 汇总 Windows `GPU Engine` 的 `Utilization Percentage`，共采集 25 个一秒样本。

CPU 百分比已除以逻辑处理器数量，表示整机归一化占用。GPU 数值为该进程各 GPU Engine 的同时刻总和。

## 限制

- 当前为 Debug 构建，工作集包含 Flutter 调试运行时、测试框架和符号开销，不能作为 Release 内存目标。
- 实际 FPS 受设备画面内容和 scrcpy 编码策略影响，不代表解码器极限吞吐。
- 本报告验证首帧和短时稳定播放；30 分钟持续延迟与泄漏由 P1-05 单独验收。

