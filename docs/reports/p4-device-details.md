# P4-05 设备基础详情验收

日期：2026-09-02

## 公开 API

`AdbToolkit.getDeviceDetails(AdbDevice)` 返回不可变的 `AdbDeviceDetails`。该模型包含：

- 品牌、制造商、型号；
- Android 版本、SDK、主 ABI；
- 当前屏幕宽高和密度；
- USB、网络或未知连接类型；
- 电量和电池温度；
- `/data` 总空间和可用空间；
- 系统 uptime；
- 查询失败组及其原因。

## 数据来源

| 信息 | 只读 ADB 查询 | 解析规则 |
| --- | --- | --- |
| 系统和硬件属性 | `getprop` | 读取 `ro.product.*`、`ro.build.version.*` |
| 屏幕尺寸 | `wm size` | 存在 Override 时优先当前 Override，否则 Physical |
| 屏幕密度 | `wm density` | 存在 Override 时优先当前 Override，否则 Physical |
| 电池 | `dumpsys battery` | level/scale 换算百分比，temperature 按 0.1℃ 换算 |
| 存储 | `df -k /data` | 以 1 KiB 块换算总量和可用量 |
| 运行时间 | `cat /proc/uptime` | 第一个秒数字段转换为 Duration |

六个查询并行执行。任意一组命令退出非零或抛出异常时，只把该组写入 `unavailable`，不会丢弃已经取得的其他字段。

## 自动测试

- 解析测试覆盖屏幕/密度 Override、电池温度、存储和 uptime。
- 聚合测试注入 `wm density` 失败，确认其他字段正常返回且只记录 density 缺失。
- 根项目 `flutter analyze`：无问题。
- 根项目 `flutter test`：63 项全部通过。

## USB 真机验证

通过 `example/integration_test/device_details_test.dart` 在 Windows 插件公开 API 上执行，结果：

- 设备：脱敏标识 `device-ad830717`
- 制造商/型号：Xiaomi 23127PN0CC
- Android：16，SDK 36
- ABI：arm64-v8a
- 屏幕：1200×2670，480 dpi
- 电池：91%
- 存储及 uptime：有效正数
- 不可用查询组：无

测试退出结果：通过。

## Demo

单设备页面会在准备会话时读取详情，显示加载、可用字段和部分字段缺失状态。视频编码能力探测失败不会覆盖已经成功显示的设备详情。

## 结论

P4-05 验收通过。

