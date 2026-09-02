# P5-05/P5-06 多虚拟屏与尺寸控制阶段记录

更新于 2026-09-02。P5-05 多应用窗口已完成；预览框自动跟随属于 P5-06，仍待完成。

## 已实现

- `ScrcpyInputController.startApplication()` 可把任意可启动应用切入当前 Session 对应的虚拟屏。
- `ScrcpyInputController.resizeDisplay()` 实现 scrcpy 4.1 类型 21 的 `RESIZE_DISPLAY` 消息。
- Demo 创建虚拟屏时可填写任意宽度、高度和 DPI，选择系统装饰、保持活跃及关闭后销毁或迁回主屏。
- 创建界面可交换宽高；虚拟屏运行时也可交换宽高切换横竖。
- 每个虚拟屏仍拥有独立 SCID、ADB forward、server、控制通道、解码器和 Texture。
- Demo 新增虚拟屏工作台，可在同一响应式网格内持续新增屏幕、选择初始应用、配置宽高/DPI、运行中任意修改宽高比例、切换应用与横竖、聚焦操作及独立关闭。
- 按当前产品决定不预设虚拟屏数量上限；单个 Session 资源失败只在对应格子显示，不阻断其他屏幕。

## 双屏真机验证

设备：Xiaomi 23127PN0CC，Android 16，USB ADB。

- display 5/8：960×540，启动 `com.miui.calculator`。
- display 6/7：540×960，启动 `com.android.settings`。
- 两个 Session 并发出帧，SCID 和本地 forward 端口不同。
- 第一块屏运行中发送 720×720 resize 消息成功。
- 关闭第一块屏后，第二块屏帧数继续增长。
- 清零旧的失败测试残留后重新执行，测试结束未产生新的 scrcpy forward 残留。

## P5-06 尚未完成

- 根据 Flutter 预览框尺寸防抖并自动调整 Android 虚拟屏。
- 连续缩放、极端宽高比以及更多应用方向策略测试。
