# P5-02 主屏应用启动/停止验收

## 结果

P5-02 于 2026-09-02 验收通过。应用清单可直接执行“在主屏启动”“强停后启动”和“停止应用”，API 与 Demo 均已完成。

## 实现

- `AdbApplicationManager.startApplication()` 先使用 Package Manager 解析明确的 Launcher Activity，再通过 `am start -n` 在默认主显示启动。
- `forceStopFirst` 可在启动前执行 `am force-stop`，覆盖应用已运行场景。
- `stopApplication()` 独立暴露，可供单设备页面和后续批量控制复用。
- 包名执行前经过严格格式校验，避免将任意 Shell 字符传入设备。
- 无 Launcher Activity、解析失败、启动失败和停止失败均抛出 `AdbApplicationOperationException`，其中保留操作类型、包名和底层诊断结果。
- Demo 每条应用提供操作菜单；操作期间仅锁定对应条目，并展示成功提示或错误。

## 自动化验证

- 单元测试覆盖启动前强停、Activity 解析、显式组件启动和无 Launcher 错误。
- 根包完整测试：73 项全部通过。
- `flutter analyze`：无问题。

## 真机验证

- 设备：ZC-3588A，Android 15，通过网络 ADB 连接。
- 成功对 `com.android.calculator2` 执行强停后启动。
- `dumpsys activity activities` 确认目标包进入 Activity 栈。
- 成功停止目标应用。
- 对无 Launcher 的 `android.auto_generated_characteristics_rro` 启动请求返回预期的应用操作异常。

## 后续

P5-03 将把主显示、已有 displayId 和新建虚拟显示建模为统一 Session 显示源；P5-04 再把本项的包名启动能力接到虚拟显示。

