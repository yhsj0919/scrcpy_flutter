# 架构与视频管线

状态：拟定架构，更新于 2026-08-31。

## 项目目标

实现一个可复用的 Flutter 插件，在任意 Flutter 布局中嵌入低延迟 Android 画面与控制会话，并组合多个会话形成设备墙。

Flutter 负责界面、布局、焦点、手势和设备管理；原生媒体组件负责编码流解码和 GPU 加速纹理渲染。禁止将每帧转换成 RGBA 后再通过 Dart 搬运，否则难以支撑设备墙。

## 选定方向

复用上游 scrcpy server 和控制协议，以 FVP/libmdk 作为第一版视频后端：

```text
Android 设备
  scrcpy-server
    |-- H.264/H.265 原始视频连接
    `-- 双向控制连接
                |
                v
ScrcpySession
  ADB + server 生命周期 + 连接管理 + 控制消息序列化
                |
                v
FVP/libmdk
  流式输入 + 硬件解码 + 平台纹理
                |
                v
Flutter Stack
  视频纹理 + 透明指针与焦点输入层
```

本项目不会使用纯 Dart 重写 scrcpy，也不会把 scrcpy 的 SDL 窗口嵌入 Flutter。

## 插件优先原则

本仓库交付物是 Flutter plugin/package，不是绑定特定业务界面的独立设备管理应用。`example/` 只承担演示、调试、集成测试和性能测试，不允许产品核心逻辑只存在于 example 中。

插件需要遵守以下边界：

- 所有对外能力从 `lib/scrcpy_flutter.dart` 或明确标记的公开库导出，宿主不得导入 `lib/src`。
- ADB、scrcpy server、视频后端和控制协议隐藏在稳定 Dart API 后面。
- UI 采用可组合 Widget；不强制宿主使用特定路由、状态管理、主题、窗口尺寸或依赖注入方案。
- 同时支持无 UI 的设备发现、文件传输、批量任务等服务 API，以及可选的视频/控制 Widget。
- 每个会话、Player、texture、ADB transport 和批量任务都有明确所有者及 `dispose/close/cancel` 语义。
- 必须支持同一宿主进程内创建多个插件实例和多个 Session，禁止依赖只能存在一次的全局可变状态。
- 插件不得擅自退出宿主、修改全局 PATH、结束非本插件进程、覆盖宿主日志策略或持久化敏感信息。
- scrcpy server、FVP/libmdk 等二进制或资源必须通过插件可复现地打包、定位和校验；同时允许高级宿主显式覆盖路径。
- 插件的 Windows 原生符号、MethodChannel/EventChannel 名称、临时路径、SCID 和端口必须避免与其他插件或实例冲突。
- 平台不支持时通过能力查询和结构化错误返回，不在加载插件时直接崩溃。

拟定的公开层次：

```text
scrcpy_flutter.dart
  |-- ScrcpyClient              插件入口、能力查询和全局资源
  |-- AdbDeviceService          发现、连接、配对和设备信息
  |-- ScrcpySession             单个视频/控制会话
  |-- ScrcpyVideoController     视频状态和画质配置
  |-- ScrcpyVideoView           可嵌入视频 Widget
  |-- ScrcpyInputRegion         可选控制覆盖层
  |-- AdbFileService            文件管理
  `-- AdbBatchTask              可取消的批量操作及逐设备结果
```

具体命名将在 P0 API 设计中确认，本文只确定职责边界。

## ADB 模块边界

ADB 有必要从 scrcpy 功能中抽离，但第一阶段不拆成独立 Git 仓库或立即发布独立 pub 包。建议在同一仓库内建立独立 package/模块，通过接口被 `scrcpy_flutter` 依赖；API 和跨平台实现稳定后，再决定是否对外发布。

推荐结构：

```text
packages/
  adb_client/                 与 scrcpy 无关的 ADB 领域 API
    lib/
      adb_client.dart
      src/model/              device、endpoint、pairing、task result
      src/service/            discover、connect、shell、sync、package
      src/transport/          transport 抽象
    test/

  adb_client_process/         Windows/macOS/Linux 的 adb 可执行文件后端
    lib/
    test/

scrcpy_flutter/               当前插件
  lib/
    src/scrcpy/               server、协议、视频、控制
  仅依赖 adb_client 的公开接口
```

未来可增加但不提前实现：

```text
adb_client_android_usb        Android USB Host ADB transport
adb_client_ohos               HarmonyOS 网络/USB transport
adb_client_web                WebUSB/Tango ADB transport
```

ADB 核心职责：

- 设备发现、USB/网络状态、connect/disconnect 和 pairing；
- shell 命令的结构化执行、超时、取消、stdout/stderr/exit code；
- sync 协议或 push/pull 文件传输；
- APK 安装/卸载和包管理；
- 设备属性、运行状态和批量任务基础设施；
- transport 能力查询、错误模型、日志脱敏和密钥接口。

scrcpy 插件职责：

- 选择并部署匹配版本的 scrcpy server；
- 创建 tunnel/forward/reverse 及 scrcpy socket；
- 解析 scrcpy 视频、音频、设备消息和控制协议；
- 视频后端、Flutter texture、输入映射和 Session 生命周期；
- 通过 ADB 抽象调用 shell、push 和端口转发，不直接解析 `adb.exe` 输出。

必须避免的耦合：

- ADB 模块不得依赖 FVP、Flutter Widget 或 scrcpy server 参数。
- scrcpy 模块不得到处直接调用 `Process.run('adb', ...)`。
- 公共 API 不返回平台 Process、Socket、USBDevice 等后端对象。
- 不把 shell 字符串拼接当作所有平台的统一 API；命令、参数和 stdin 应结构化传递。
- 不为了未来 Web/移动端，在 P0 就实现完整 ADB wire protocol；先用 transport 抽象和桌面 process 后端交付 Windows。

## 已确认的上游能力

### scrcpy

正常模式下，scrcpy 会在编码媒体包之外传输设备、媒体流、会话和帧元数据。该协议属于内部协议，可能随版本变化，因此客户端和 server 必须保持版本匹配。

当前 server 启用 `raw_stream=true` 后会关闭：

- 设备元数据；
- 每帧元数据和 PTS 头；
- 连接开始时的 dummy byte；
- 编解码器和会话元数据。

此时视频连接输出可交给播放器处理的编码裸流。第一版选择 H.264，因为其硬件解码兼容性最广。

参考资料：

- <https://github.com/Genymobile/scrcpy/blob/master/doc/develop.md>
- <https://github.com/Genymobile/scrcpy/blob/master/server/src/main/java/com/genymobile/scrcpy/Options.java>

### FVP/libmdk

FVP 提供跨平台硬件解码及 Flutter 纹理渲染。其渲染路径包括 Windows D3D11、Apple Metal 和 Linux OpenGL，默认启用硬件解码器。

libmdk 除了支持常见网络视频协议，也支持由调用方主动追加数据：

```text
setMedia("stream:scrcpy")
appendBuffer(data, size)
```

FVP 自动生成的 FFI binding 已包含 `appendBuffer` 函数指针。截至本文档更新时，公开的 Dart `Player` 类还没有易用的 `appendBuffer(Uint8List)` 封装。预期只需维护一个很薄的扩展或补丁，不需要自行实现解码器和 GPU 渲染器。

参考资料：

- <https://github.com/wang-bin/fvp>
- <https://github.com/wang-bin/fvp/blob/master/lib/src/generated_bindings.dart>
- <https://github.com/wang-bin/mdk-sdk/wiki/Player-APIs>

## 视频接入方案

启动 `scrcpy-server` 时启用视频、关闭音频、选择 H.264，并设置 `raw_stream=true`。会话层持有视频连接，并把收到的数据持续送入可复用的 FVP Player：

```text
连接数据 -> FVP appendBuffer -> 解复用/解码 -> GPU 渲染 -> Flutter 纹理
```

连接读取边界不需要与完整帧或 NAL 边界一致，媒体后端负责将输入作为连续字节流处理。

拟定的低延迟参数需要通过原型验证：

```text
媒体地址：stream:scrcpy-<session-id>
最小缓冲：0 ms
积压时丢弃旧包：开启
调度方式：尽可能收到即解码、解码即渲染
Windows 解码器优先级：MFT/D3D11，失败后回退软件解码
```

本地 TCP/HTTP 桥接仅保留为诊断方案。生产环境优先直接使用 `appendBuffer`，避免额外端口、生命周期和缓存。

## Flutter 输入覆盖层

显示组件使用 `Stack` 组合视频纹理和透明输入层。输入层负责鼠标、触摸、滚轮、键盘和文本事件，然后通过会话发送 scrcpy 控制消息。

坐标转换流程：

```text
Flutter 局部坐标
  -> 排除黑边或裁剪区域
  -> 转成实际视频视口内的归一化坐标
  -> 映射到当前编码画面的宽高
  -> 序列化为 scrcpy 控制事件
```

实现时必须正确处理 pointer ID、按键状态、action button，以及 down/move/up 顺序，并与固定的 scrcpy server 版本一致。

## 设备墙约束

设备墙不能假设每个窗口都需要全分辨率、全帧率解码。后续调度器需要区分聚焦、可见和后台会话。候选默认值为普通格子使用 540p/720p、10–20 FPS，聚焦设备使用更高画质，设备墙默认关闭音频。

确定并发能力前，必须测试 1、4、8、16 个会话下的 Player 复用、硬件解码并发上限、纹理显存、线程数量，以及 USB/网络总带宽。

## 已知风险与待验证事项

1. `raw_stream=true` 会移除 PTS 和会话元数据，适合显示原型；录制和音视频同步可能需要切回带帧头模式。
2. 分辨率和方向变化依赖新的编码参数集，需要验证 FVP 能否保持播放、更新宽高比并正确调整或重建纹理。
3. 触控映射必须使用当前编码尺寸，不能只依赖设备物理 `wm size`。
4. scrcpy 协议属于内部协议，server、启动参数和控制序列化代码必须按版本绑定。
5. FVP 仓库使用 BSD-3-Clause，但 libmdk SDK 的发行和商业授权条款需要独立确认。
6. 多 Player 硬解和多纹理合成必须在目标 Windows 硬件上实测。

## 版本管理策略

- 固定明确的 scrcpy release/tag，并携带匹配的 server 文件。
- 将版本相关的启动参数和控制序列化封装在版本适配层。
- 固定 FVP/libmdk 版本，使流式输入补丁足够小，便于升级或提交上游。
- 升级 scrcpy 前执行协议测试和真实设备冒烟测试。

## 暂缓决定的事项

- 音频由同一个 FVP Player 处理，还是使用独立后端。
- 录制使用 scrcpy 带帧头数据，还是建立单独录制会话。
- 大规模设备墙是否需要专用原生后端替代“一台设备一个播放器”。
- Windows 之后的平台支持顺序。

## 参考实现评估：scrcpy_video_view 0.0.1

评估日期：2026-08-31。发布包：<https://pub.dev/packages/scrcpy_video_view>，源码：<https://github.com/balvinderz/scrcpy_video_view>。

该项目是一个 macOS 单设备、仅视频的技术原型。它在 Dart 中负责 ADB 和 scrcpy server 生命周期、读取带 12 字节帧头的 H.264 包，再通过 MethodChannel 将每个编码包送入 Swift；Swift 使用 VideoToolbox 解码并通过 `FlutterTexture` 输出最新的 `CVPixelBuffer`。

对本项目有直接参考价值的部分：

- `ScrcpyVideoController` 的 idle/starting/streaming/stopping/error 状态模型；
- `ScrcpyVideoException` 和机器可读错误码设计；
- ADB 设备列表解析、动态分配 forward 端口、随机 SCID 和启动重试；
- server 进程、ADB forward、远端 server 文件和 Flutter texture 的回收顺序；
- scrcpy 12 字节帧头、config/keyframe/PTS 的解析及单元测试；
- Flutter `BoxFit` 视频组件和宽高状态通知；
- macOS VideoToolbox、SPS/PPS、Annex-B 到 AVCC、FlutterTexture 的实现，可作为未来 macOS 后端参考。

不适合直接作为本项目依赖或 Windows 设备墙基础的原因：

1. 0.0.1 只注册了 macOS 平台，Windows、Linux、移动端均未实现。
2. 它只实现视频，没有控制、音频、旋转恢复和多设备墙。
3. 每个编码包从 socket 进入 Dart，再作为 `FlutterStandardTypedData` 通过 MethodChannel 复制到 Swift，并且逐帧 `await`。单设备原型可接受，但不是设备墙的理想数据路径。
4. 代码把视频开头读取为一个 12 字节的 `codec id + width + height` 结构；scrcpy 4.1 当前协议是先发送 4 字节 codec id，再发送独立的 12 字节 session packet。该实现没有固定版本白名单，却直接使用本机安装的 scrcpy 和 server，因此对 4.1 存在明确兼容风险。
5. 它使用固定远端 server 路径，并在新会话开始时清理相同前缀的旧 forward；同一设备多会话会互相影响。
6. macOS 插件只记录一个待清理会话，不适合多 Session 异常退出清理。
7. VideoToolbox 输出被指定为 BGRA，设备墙场景需要进一步测量像素格式转换和内存带宽成本。

结论：吸收其 Dart API、错误模型、生命周期测试和协议测试思路，但不直接引入该包。Windows 第一版仍使用 FVP/libmdk；协议层应按 scrcpy 4.1 实现并保留 session packet，而不是复制该包的旧流头假设。未来 macOS 支持可以参考其 VideoToolbox 代码。
