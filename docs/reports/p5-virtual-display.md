# P5-04 单虚拟屏闭环

完成日期：2026-09-02。功能实现和两台不同厂商、不同 Android 版本真机验收均已通过。

## 实现

- 连接层将 `ScrcpyVirtualDisplaySource` 统一转换为 scrcpy-server 4.1 虚拟显示参数。
- 控制消息序列化器支持类型 16 的 `START_APP`：1 字节类型、1 字节 UTF-8 长度及最多 255 字节应用名称。
- 虚拟显示连接建立后，通过该 Session 自己的控制通道启动应用，因此应用会被投递到对应 display，而不是设备主屏。
- `ScrcpyInputController.startApplication()` 可在会话期间启动或切换应用；`+包名` 表示启动前强制停止。
- Demo 应用列表新增“在虚拟屏打开”和“强停后在虚拟屏打开”，每次创建独立 Session、SCID、Texture 和控制通道。

## 首台真机结果

- 设备：rockchip ZC-3568K，Android 11，网络 ADB。
- 配置：1280×720、240 DPI、关闭系统装饰、keep-active、H.264。
- scrcpy server：成功创建 displayId 2。
- 应用：`com.android.calculator2` 成功启动到 display 2。
- 视频：Native Texture 解码尺寸 1280×720，成功收到首帧。
- 控制：虚拟屏中心点击消息发送成功。
- 清理：测试停止后未发现 scrcpy 虚拟显示或 ADB forward 残留。

## 第二台真机结果

- 设备：Xiaomi 23127PN0CC，Android 16，USB ADB。
- 应用：`com.miui.calculator` 成功启动到新建 displayId 3。
- 初始配置：1280×720、240 DPI、关闭系统装饰、keep-active。
- 应用请求竖屏后，视频配置和 Native Texture 正常从横屏切换为 720×1280并继续出帧。
- 虚拟屏中心触摸发送成功。
- 停止后没有活动的 scrcpy DisplayDevice、该 display 上的 Activity 或 ADB forward。

第二次测试最初在 Texture 重建窗口查询旧 ID，返回 `Unknown texture`。验收脚本已改为识别并重试这一正常竞态；实际 Flutter Widget 始终跟随控制器中的最新 Texture ID。

协议实现对照 [scrcpy 控制消息定义](https://github.com/Genymobile/scrcpy/blob/v4.1/app/src/control_msg.h) 与 [虚拟显示文档](https://github.com/Genymobile/scrcpy/blob/v4.1/doc/virtual-display.md)。
