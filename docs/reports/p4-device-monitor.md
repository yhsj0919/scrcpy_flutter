# P4 设备热插拔监视器验收报告

更新日期：2026-09-02

## 已实现

- `ScrcpyDeviceMonitor` 通过插件公开 API 周期发现设备
- 输出完整设备列表及 `added`、`removed`、`changed` 差异
- USB、网络、paired、offline、unauthorized 状态沿用 typed ADB 模型
- 防止重叠刷新，支持手动刷新、停止和关闭
- Demo 默认每 2 秒自动更新，设备变化显示摘要提示
- 网络连接、断开、配对后的刷新复用同一监视器

## 自动测试

- [x] unauthorized USB 设备首次加入
- [x] unauthorized → device 状态变化
- [x] offline 网络设备加入
- [x] 设备移除
- [x] 非法轮询间隔
- [x] stop/close 生命周期

## 真机测试

- 设备：ZC-3588A，Android 15
- 连接：`192.168.5.4:5555`
- 流程：网络 ADB 在线 → disconnect → 监视器确认不再处于 device → connect → 监视器确认恢复 device
- 结果：全部通过，finally 再次确保设备恢复连接

### USB 物理拔插

- 设备：23127PN0CC，序列号 `56ea8768`
- 初始状态：USB、`device`、已授权
- 流程：在线 → 物理拔出 → 监视器 `removed` → 重新插入 → 监视器 `added/changed` 且恢复 `device`
- 检测用时：完整测试 12 秒
- 结果：全部通过

## 状态覆盖

- [x] device
- [x] offline
- [x] unauthorized → device
- [x] USB removed → added
- [x] 网络 disconnect → connect

offline 与 unauthorized 使用确定性设备快照测试验证，物理 USB 和网络连接生命周期使用真机验证。

## 结论

P4-01 验收通过。
