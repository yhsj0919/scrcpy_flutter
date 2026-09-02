# P3 基础导航与输入验收报告

验收日期：2026-09-02

## 环境

- 宿主：Windows
- 设备：ZC-3588A，Android 15
- 连接：网络 ADB，`192.168.5.4:5555`
- scrcpy server：4.1
- 视频：原生 Windows Texture，最大尺寸 1280、最大 30 FPS

## 自动化清单

- [x] 点击：DOWN/UP
- [x] 长按：DOWN，保持 600 ms，UP
- [x] 拖动/滑动：DOWN，连续 5 个 MOVE，UP
- [x] 鼠标滚轮：SCROLL
- [x] 双指放大、双指缩小
- [x] Back、Home、Recent Apps
- [x] Power 后 Wake，并在异常清理路径中保证 Wake
- [x] 音量减、音量加
- [x] Enter、Backspace、Forward Delete
- [x] 基础 ASCII 文本 `scrcpy_flutter_123`

执行命令：

```powershell
flutter test integration_test\basic_control_test.dart -d windows `
  --dart-define=SCRCPY_DEVICE_SERIAL=192.168.5.4:5555
```

结果：全部通过。加入双指手势后的复测中，控制序列执行期间原生视频帧计数由 2 增长至 41，最终 session 为 `streaming`、视频为 `ready`，未发生 socket 中断或协议错位。

## 单元与 Widget 回归

`flutter test`：40 项全部通过。其中输入层覆盖点击坐标、禁用状态、长按事件顺序、拖动归一化、滚轮、键盘映射、已映射键拦截和系统组合键放行。

## Demo

设备会话页提供 Back、Home、Recent Apps、Power、Wake、音量减/加，以及基础文本输入和发送按钮。视频表面继续负责鼠标点击、长按、拖动、滚轮和键盘焦点输入。

## 结论

P3-04 验收通过。自动化证明全部控制消息可在同一真实 control socket 上连续发送并保持视频流稳定；涉及具体 Android 前台页面行为的视觉效果仍可通过 Demo 人工复核。
