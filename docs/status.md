# 实现进度

更新于 2026-09-11。逐项勾选、验收证据和交接记录以[开发计划](development-plan.md)为准。

## 当前状态

| 模块 | 状态 | 说明 |
| --- | --- | --- |
| Flutter 插件公开 API | 进行中 | 已有客户端、会话、视频控制器、视频 Widget 和输入层。 |
| Windows 内置 ADB | 已完成 | ADB 与依赖 DLL 随插件构建产物分发。 |
| Android ADB | 基本链路已验证 | 原生后端已完成验证码配对、网络连接、shell、push 和断开；Samsung SM-S9110 已成功连接，设备发现延后。 |
| scrcpy server 5.0.1 | 已完成 | server 随插件分发，支持部署、启动、forward 和清理。 |
| 视频协议与显示 | Android 基本验证通过 | Windows 使用 Media Foundation；Android 原生链路已真机出图，稳定阶段无输入队列积压，用户确认延迟表现良好。 |
| 动态尺寸与方向 | 待验收 | 已能重建解码器和 Texture，待连续旋转真机验证。 |
| 控制协议 | 进行中 | 已实现触摸、滚轮、按键和文本消息。 |
| 输入覆盖层 | 进行中 | 已实现鼠标、拖动、滚轮、键盘和 contain/cover 坐标映射。 |
| 音频 | Android 待验收 | Windows Opus 解码播放、静音和工作台单音频焦点已实现；Android 已接入同会话原生 MediaCodec/AudioTrack 链路，等待真机验证。 |
| 虚拟显示工作台 | 待验收 | 支持任意应用、尺寸/方向切换、触摸和断线重连。 |
| Demo | 进行中 | 支持设备列表、详情、画面启停、画质参数、基础控制、虚拟显示工作台和主屏/工作台/设备墙截图。 |
| 自动化测试 | 进行中 | 覆盖公开 API、ADB、视频拆包、控制序列化、输入映射和 Texture 生命周期。 |
| 设备墙 | 进行中 | 已实现多 Session 管理，以及跨设备主屏和虚拟应用窗口的统一响应式网格；等待基本验证，后续加入资源调度。 |
| 诊断与性能指标 | 已完成 | 支持 Session/进程有界时间序列、聚合指标、Windows 进程 GPU 采样和脱敏 JSON 诊断报告导出。 |

## 已确认技术路线

- Windows 主线使用 Media Foundation 原生解码和 Flutter Texture。
- 编码帧保留 scrcpy 5.0.1 的配置、关键帧和 PTS 信息。
- Dart 不搬运逐帧 RGBA 像素；原生线程转换并只保留最新显示帧。
- ADB 领域接口与桌面进程实现已拆成仓库内独立 package。
- Windows 仍是当前可交付主线；Android 的单设备网络 ADB、scrcpy socket 与媒体基本链路已接入，等待真机验收。
- Windows 零拷贝外部纹理因当前 Flutter 渲染器绑定失败并导致无响应而延期；已恢复稳定的 PixelBuffer 路径。

## 当前验收重点

1. 真机横竖屏各连续操作 10 分钟，确认坐标、按键和控制协议稳定。
2. 连续旋转 20 次，确认尺寸、纹理和输入映射同步更新。
3. 记录首帧、端到端延迟、FPS、CPU、GPU 和内存。
4. 完成 Back、Home、Recent Apps、Power、Wake、音量、Enter、Delete 等控制清单。
5. 完成音频基本断连验证后进入跨设备设备墙阶段。

## 后续里程碑

- 延期验收：热插拔、重连以及视频和音频的长时间稳定性。
- 设备墙：多会话隔离、响应式网格、聚焦视图、默认画质与逐窗口画质设置。
- 平台验证：Android 宿主、HarmonyOS 控制 Android，以及条件允许时的 Web。

