# P10 Linux 与 macOS 宿主适配记录

更新于 2026-09-14。

## 已接入基线

- `ProcessAdbClient` 继续作为桌面平台统一 ADB 后端，上层设备、配对、文件、应用和 Session API 不增加平台分支。
- Linux 与 macOS 随插件分发 Google Platform-Tools 37.0.1 的官方 ADB。
- 两个平台复用内置 scrcpy-server 4.1、固定 SHA-256 校验和现有 socket/control 协议。
- Linux 插件 CMake 已建立资源安装规则；macOS 插件和 CocoaPods resource bundle 已建立。
- Linux 由 CMake 设置内置 ADB 可执行权限；macOS 在 Pod 准备阶段设置，运行时不会修改已签名应用包。显式传入的系统命令名称不受影响。
- macOS 视频通道已接入 VideoToolbox 异步 H.264 解码：解析 Annex-B SPS/PPS，提交长度前缀样本，并通过 `CVPixelBuffer` Flutter Texture 输出最新帧。动态尺寸继续复用 Dart Session 的 Texture 重建流程。
- macOS 音频通道已接入 `AVAudioConverter` 与 `AVAudioEngine`：系统 Opus 解码为 48 kHz 双声道 PCM，经独立 `AVAudioPlayerNode` 播放；支持逐 Session 静音、音量、焦点切换和播放统计，最多排队 12 个 PCM 缓冲。
- macOS 截图锁定最新 `CVPixelBuffer`，按 stride 将 VideoToolbox 的 BGRA 转成公共 API 使用的 RGBA，不暂停解码。
- macOS 录屏使用 `AVAssetWriter` 将收到的 H.264 直接封装为 MP4，不重复编码；从关键帧开始写入，停止时异步完成容器并返回实际写入帧数。
- Linux 视频通道已接入 GStreamer：`appsrc -> h264parse -> decodebin -> videoconvert -> appsink`，由系统自动选择可用的硬件或软件 H.264 解码器，并通过 `FlPixelBufferTexture` 输出 RGBA 最新帧。输入限制为 2 MiB、输出只保留 1 帧，避免播放队列持续积压。
- Linux 音频通道复用 GStreamer 解码 Opus，通过 `autoaudiosink` 选择 PipeWire、PulseAudio 或系统可用输出；支持逐 Session 静音、音量、焦点切换和基础缓冲统计。压缩包队列最多保留 12 个，积压时丢弃旧包。
- Linux 截图从 `FlPixelBufferTexture` 的最新 RGBA 帧复制稳定快照，不暂停视频管线。
- Linux 录屏使用独立 GStreamer `h264parse -> mp4mux` 管线直接封装 H.264；以首个关键帧为起点重建时间戳，停止时等待 EOS 完成 MP4 尾部。
- Linux 缺少 GStreamer 开发模块时插件仍可构建，音视频创建会返回结构化 `unsupported_capability`；发行环境需提供 `gstreamer-1.0`、`gstreamer-app-1.0`、`gstreamer-video-1.0` 以及 H.264、Opus 和音频输出插件。
- example 已加入标准 Linux GTK runner，Flutter 生成的插件注册文件会把 `scrcpy_flutter` 原生插件接入应用，bundle 安装规则会携带插件声明的 ADB 与 scrcpy server 资源。
- example 已加入标准 macOS CocoaPods runner，并注册 `ScrcpyFlutterPlugin`。示例应用不启用 App Sandbox，使内置 ADB 能启动子进程、访问 USB 和建立本地/局域网连接。

## 下一阶段

1. 在 macOS 目标机完成 VideoToolbox/CoreAudio 编译、音视频首帧、旋转、低延迟、焦点和资源释放验证。
2. 在 Linux 目标机完成 GStreamer 编译、硬件/软件解码选择、首帧、旋转、低延迟和资源释放验证。
3. 在 Linux 目标机验证 PipeWire/PulseAudio 输出，在 macOS 目标机验证 CoreAudio 输出；两端验证静音、音量、焦点切换和音频设备变化。
4. 在 macOS 目标机检查 CocoaPods 插件注册和应用 resource bundle。
5. 在目标平台集中验证 ADB、mDNS、视频、输入、音频、截图录屏与生命周期。

## 延后测试

- Android mDNS 真机发现与动态端口自动重连。
- Android Debug/Release、热重启、插件 detach 和资源释放。
- Android 截图、录屏文件权限和 Android 10/11/12+ 音频兼容。
- Linux 与 macOS 的全部目标机测试，待对应环境可用后集中执行。
