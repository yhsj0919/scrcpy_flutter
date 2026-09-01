# 当前架构

更新于 2026-09-01。

## 目标与边界

本仓库交付可嵌入其他 Flutter 应用的插件。`example/` 只负责演示、真机验证和集成测试。

- Flutter 负责设备管理、布局、状态、输入覆盖层和公开 API。
- ADB 模块负责设备发现、命令执行、文件传输及端口转发。
- scrcpy 会话层负责 server 部署、socket 生命周期、4.1 协议拆包和控制消息。
- 平台原生视频后端负责硬件解码和 Flutter Texture；编码帧不通过 MethodChannel 逐帧复制。

## 当前 Windows 数据流

```text
内置 adb.exe
  -> 部署并启动内置 scrcpy-server 4.1
  -> video socket：codec/session/frame metadata + H.264
  -> Dart 协议拆包
  -> Windows Media Foundation 解码
  -> 最新帧 PixelBuffer Texture
  -> Flutter ScrcpyVideoView

control socket
  <- ScrcpyInputLayer
  <- 鼠标、触摸、滚轮和键盘事件
```

Windows 原生后端按帧接收编码数据，保留配置帧、关键帧和 PTS。颜色转换在原生后台线程执行，只保留待显示的最新帧，避免解码积压持续增加延迟。会话尺寸变化时重建解码器和 Texture。

## 公开组件

```text
ScrcpyClient
  |-- 设备发现与能力查询
  `-- ScrcpySession
        |-- ScrcpyVideoConnection
        |-- ScrcpyVideoController
        |-- ScrcpyVideoView
        `-- ScrcpyInputController / ScrcpyInputLayer
```

宿主只应导入 `package:scrcpy_flutter/scrcpy_flutter.dart`，不得依赖 `lib/src`、原生句柄、进程或 socket。资源路径允许高级宿主覆盖，但默认使用插件随包分发的 ADB 和 scrcpy server。

## ADB 模块

ADB 在同一仓库拆成两个 package：

- `packages/adb_client`：与后端无关的模型、接口和错误。
- `packages/adb_client_process`：桌面进程后端；Windows 默认定位插件内置 ADB。

后续 Android USB Host、HarmonyOS 和 WebUSB 可新增 transport 实现，不改变 scrcpy 会话的上层 API。

## 输入映射

`ScrcpyInputLayer` 覆盖在 Texture 上，依据 `BoxFit`、Alignment、黑边及裁剪计算归一化视频坐标，再由控制器映射到当前编码尺寸并序列化为 scrcpy 4.1 控制消息。

映射到 Android 的普通按键由视频焦点处理；Ctrl、Alt、Meta 等宿主系统组合键放行。项目不拦截 Windows 全局键或系统音量键。

## 多会话约束

每个会话独立持有 SCID、ADB forward、视频/控制 socket、解码器和 Texture。任何一台设备断开或解码失败都不能影响其他会话。设备墙阶段会根据聚焦、可见性和后台状态动态调整分辨率、FPS 与码率。

## 平台扩展方向

- Windows：Media Foundation，当前主线。
- macOS/iOS：评估 VideoToolbox。
- Android：评估 MediaCodec 与 Surface Texture。
- Linux：评估 FFmpeg/VA-API 或 GStreamer 原生后端。
- HarmonyOS：仅作为宿主控制 Android，视频后端单独验证。
- Web：仅在 WebUSB/WebSocket transport 与 WebCodecs 条件满足时实现。

各平台复用 Dart 会话、协议和 Widget API，只替换 ADB transport 与原生视频后端。

## 版本策略

- scrcpy server、启动参数和控制协议固定为同一明确版本。
- 升级 scrcpy 前执行协议 fixture、真机视频、控制和资源回收回归。
- 原生后端通过内部接口隔离，不向宿主暴露 Media Foundation 类型。
- 二进制资源必须随插件可复现地打包，并保留对应许可证和校验记录。
