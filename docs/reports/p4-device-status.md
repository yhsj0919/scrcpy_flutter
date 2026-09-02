# P4-07 设备运行状态验收

日期：2026-09-02

## 公开能力

`AdbToolkit.status()` 返回 `AdbDeviceStatusMonitor`，状态流包含：

- 整机 CPU 使用率；
- 总内存和可用内存；
- `/data` 总空间和可用空间；
- 非 loopback 网络接口累计接收/发送字节；
- 电量和电池温度；
- 当前前台应用包名；
- 当前前台应用 PID、CPU、PSS 和 RSS；
- 设备支持时的前台应用 GPU 忙碌率和 GPU 内存；
- 设备支持时的整机 GPU 忙碌率、当前频率和数据源；
- 采集失败组及原因。

## 采集与负载限制

| 状态 | 数据源 |
| --- | --- |
| CPU | `/proc/stat`，使用相邻样本 total/idle 差分 |
| 内存 | `/proc/meminfo` 的 MemTotal、MemAvailable |
| 存储 | `df -k /data` |
| 网络 | `/proc/net/dev`，排除 lo 后汇总 |
| 电池 | `dumpsys battery` |
| 前台应用 | `dumpsys activity activities` 的 topResumedActivity/ResumedActivity |
| 应用 PID/CPU | `pidof -s` 与 `/proc/<pid>/stat`，同整机 tick 做相邻样本差分 |
| 应用内存 | `dumpsys meminfo <package>` 的 TOTAL PSS 与 `/proc/<pid>/status` 的 VmRSS |
| 应用 GPU | 厂商 `dumpsys gpu` 的 UID active duration 差分/墙钟采样间隔，以及 PID GPU memory |
| 整机 GPU | 优先 devfreq `*gpu*/load`，备用 Mali utilization 或 Qualcomm KGSL gpubusy 差分 |

- 默认轮询间隔为 5 秒。
- 小于 2 秒的间隔会被拒绝，防止 UI 配置造成持续 ADB 压力。
- 并发调用 `refresh()` 会复用同一个进行中的 Future，不产生重叠采集。
- 六组只读查询并行执行，单组失败只进入 `unavailable`。
- `stop()` 停止定时采样，`close()` 同时关闭状态流；Demo 跟随页面销毁调用 close。

## Demo

单设备页面增加“设备运行状态”卡片，可选择 2、5、10 或 30 秒更新 CPU、内存、存储、网络、电池、温度和前台应用，并展示前台应用 PID、CPU、PSS、RSS、GPU 忙碌率、GPU 内存、采样时间及不可用字段。默认 5 秒；首次 CPU/GPU 样本显示“采样中”，第二次起显示差分结果。应用或 PID 变化时会重置应用采样基线。切换间隔时先关闭旧监视器，并使用代次校验避免快速切换产生重复轮询。

Android 没有统一公开的单应用 GPU 百分比接口。GPU 百分比和 GPU 内存属于尽力采集：设备 `dumpsys gpu` 提供 UID active duration 和 PID memory 时显示，否则 Demo 明确显示“不支持或采样中”。通用 `dumpsys gfxinfo` 是 UI 帧渲染耗时，不替代 GPU 利用率。

整机 GPU 同样属于厂商可选能力。监视器不会汇总各 UID 数据冒充整机利用率，而是只接受驱动全局节点：devfreq load 为首选，Mali utilization 和 Qualcomm KGSL busy/total 为备用。可同时读取 devfreq `cur_freq` 时显示 MHz，并通过 `deviceGpuSource` 说明来源；没有可读驱动节点时返回 null。

## 测试

解析测试覆盖：

- CPU 差分百分比；
- 内存 kB 到字节换算；
- 多网络接口汇总并排除 loopback；
- Window 和 Android 16 Activity 两种前台应用格式；
- 小于 2 秒轮询间隔的拒绝逻辑。

根项目结果：

- `flutter analyze`：无问题。
- `flutter test`：65 项全部通过。

## 真机结果

Windows 上通过 `example/integration_test/device_status_test.dart` 对当前 Android 16 设备连续采样：

- 脱敏设备：`device-017f2353`
- CPU：5.9%
- 可用/总内存：927727616 / 4011929600 bytes
- 网络累计接收/发送：569345856 / 306415357 bytes
- 前台应用：`com.palsmon.app`
- 前台应用 PID：30425
- 前台应用 CPU：1.7%
- 前台应用 PSS：185054208 bytes
- 前台应用 RSS：344317952 bytes
- 前台应用 GPU：0.0%（采样窗内无新增 active 时间）
- 前台应用 GPU 内存：514564096 bytes
- 整机 GPU：0.0%，300 MHz
- 整机 GPU 来源：`devfreq load`
- 电池、存储：有效范围
- 不可用采集组：无

测试通过，监视器在 finally 中关闭。

## 结论

P4-07 验收通过。

