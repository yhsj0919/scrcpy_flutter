# P4-03 示例应用单设备页面验收

日期：2026-09-02

## 验收范围

- 设备列表选择并进入单设备页面。
- 启动、停止及意外断线后的自动重连。
- Native Texture 实时画面及鼠标、键盘、多点触摸输入。
- Back、Home、最近任务、电源、唤醒、音量和双指缩放控制。
- 文本输入及双向剪贴板操作。
- 最大尺寸、FPS、码率、编码格式和 Android 编码器选择。
- 会话状态、错误、帧率、帧数、包数、流量和连接诊断。

连接诊断展示 SCID、本地转发端口、视频流尺寸、编码配置、请求画质、渲染后端和自动重连次数。

## 边界审计

`example/lib` 只导入 Flutter 和插件公开入口 `package:scrcpy_flutter/scrcpy_flutter.dart`。检索未发现：

- `package:scrcpy_flutter/src` 内部导入；
- `package:adb_client` 直接导入；
- `dart:io`、Socket、MethodChannel；
- ADB 命令、scrcpy 控制消息序列化或视频解码实现。

因此示例只负责 UI 和公开对象的生命周期编排，ADB、scrcpy 协议及解码仍位于插件实现中。

## 自动验证

- 根项目 `flutter analyze`：通过，无问题。
- 根项目 `flutter test`：61 项通过。
- example `flutter test`：1 项通过。
- example `flutter build windows --release`：通过。

构建产物：`example/build/windows/x64/runner/Release/scrcpy_flutter_example.exe`。

随 Release 产物确认存在：

- `adb.exe`
- `AdbWinApi.dll`
- `AdbWinUsbApi.dll`
- `scrcpy-server-v4.1`

## 人工验收依据

本阶段前序真机验证已经覆盖实时画面、颜色修正、旋转、鼠标拖动、键盘映射、多点触摸、剪贴板、动态画质、USB 热插拔及 scrcpy server 被终止后的自动恢复。P4-04 的两小时连续稳定性测试按开发决策延期，不作为本项完成条件。

## 结论

P4-03 验收通过。Demo 可继续作为插件公开 API 的单设备功能验证入口。

