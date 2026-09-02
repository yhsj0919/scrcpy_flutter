# P3 多指与手势模拟验收报告

验收日期：2026-09-02

## 实现

- `ScrcpyInputLayer` 使用 Flutter 原始 pointer ID，每个触点独立映射并发送。
- 公开 `ScrcpyGestureSimulator.pinch()`，宿主无需自行拼装双指协议消息。
- 手势参数采用归一化坐标，支持中心、方向、起止跨度、步数、持续时间和自定义 pointer ID。
- 双指手势顺序为第一触点 DOWN、第二触点 DOWN、成对 MOVE、第二触点 UP、第一触点 UP。
- 异常清理使用 `finally`，释放已经按下的触点。
- 路径越界、相同 pointer ID、零方向、非法步数和时长会在发送前拒绝。

## 自动测试

- [x] 两个同时存在的 Flutter pointer ID 保持独立
- [x] 两个触点分别具有 DOWN/MOVE/UP 完整序列
- [x] CANCEL 保留对应 pointer ID 并转发
- [x] 模拟 pinch 产生平衡的双触点序列
- [x] 放大与缩小终点坐标准确
- [x] 非法路径不会发送部分事件

输入测试共 21 项，全部通过。

## 真机测试

- 设备：ZC-3588A，Android 15，网络 ADB
- scrcpy server：4.1
- 序列：双指由跨度 0.18 扩展至 0.5，再由 0.5 收缩至 0.18
- 每组持续 160 ms，每个触点使用独立 64 位 ID
- 结果：测试通过，视频帧 2→41，session 保持 `streaming`，视频保持 `ready`

## Demo

设备控制区增加“双指放大”和“双指缩小”按钮，便于在不具备触摸屏的 Windows 主机上验证和使用多指缩放。

## 结论

P3-06 验收通过。协议序列、Flutter 多触点透传、异常释放和真实 control socket 均已覆盖。

