# P5 ADB 与 scrcpy 硬边界

完成日期：2026-09-02。

## 结果

- `adb_client` 独立公开设备发现、连接/断开、验证码配对、应用、文件、设备详情、运行状态和批量包管理。
- `scrcpy_flutter` 只公开 server、会话、视频、输入控制等 scrcpy 领域 API，并单向依赖 `AdbClient`。
- 删除原有 `ScrcpyApplication*`、`ScrcpyFile*`、`ScrcpyDeviceStatus*`、`ScrcpyBatch*` 等类型以及 `ScrcpyClient` 上的 ADB 代理方法；不提供弃用别名或兼容转发。
- `scrcpy_flutter.dart` 不再重导出 `adb_client`，宿主和 Demo 必须显式导入两个包。
- `ScrcpyCapabilities` 删除设备发现、USB ADB、网络 ADB和无线配对字段，只保留视频与实时控制能力。

## 应用枚举边界

ADB 包的应用列表保持纯 ADB 命令组合：`pm list packages`、`dumpsys package packages` 和 `cmd package query-activities`，名称不可解析时回退为包名。scrcpy 包在此基础上提供可选的名称增强：利用随插件分发的 server 解析设备当前语言的应用标签；依赖方向仍然只有 scrcpy → ADB，独立 ADB 包不依赖 scrcpy。

## 验证

- `packages/adb_client`: 18 项测试通过。
- `scrcpy_flutter`: 55 项测试通过。
- `example/test/widget_test.dart`: 2 项测试通过。
- 根工程 `flutter analyze`: 无问题。
- USB 真机应用列表：140 个包、3 个用户应用、20 个可启动应用，约 675 ms。
- USB 真机应用控制：启动/停止计算器及无启动 Activity 拒绝路径通过。
