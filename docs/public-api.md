# P0 公开 API 基线

更新于 2026-09-03。宿主按使用范围导入两个独立入口：

```dart
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';
```

不得导入 `package:scrcpy_flutter/src/...`，也不需要直接依赖 process、平台解码器或 scrcpy 上游内部对象。

## 初始化与能力查询

```dart
final client = createDefaultScrcpyClient();
final adb = AdbToolkit(client.adbClient);
final capabilities = client.capabilities;
```

如宿主需要使用自己校验过的资源，可显式覆盖路径：

```dart
final client = createDefaultScrcpyClient(
  adbExecutablePath: r'C:\managed-tools\adb.exe',
  scrcpyServerPath: r'C:\managed-tools\scrcpy-server-v4.1',
);
```

Windows 默认 Client 使用随插件分发的官方 ADB。`capabilities` 只描述 scrcpy 的视频和实时控制能力，不再混入设备发现、USB、网络连接或配对等 ADB 能力。

## 设备发现

```dart
final devices = await adb.discoverDevices();
for (final device in devices) {
  print('${device.redactedSerial}: ${device.state.name}');
}
```

ADB 领域能力位于独立的 `adb_client` package，`scrcpy_flutter` 不再重导出它。连接、配对、Wireless Debugging mDNS 发现、shell、sync、包管理和 forward 均有 typed interface，宿主不拼接 shell 字符串。

`AdbToolkit.discoverDevices()` 会合并 `adb devices -l` 与 mDNS connect 服务。在线设备优先；尚未在线的已配对设备使用 `AdbDeviceState.paired`，并通过 `lastSeenAt` 提供最后发现时间。pairing 广播只用于配对流程，不进入设备列表。

## 会话

```dart
final session = client.createSession(
  const ScrcpySessionConfiguration(
    deviceSerial: '实际序列号只保存在内存',
    video: ScrcpyVideoOptions(
      maxSize: 1920,
      maxFps: 60,
      bitRate: 8000000,
      codec: ScrcpyVideoCodec.h264,
      encoder: 'c2.rk.avc.encoder', // 可选，留空由 scrcpy 选择
    ),
  ),
);

await session.prepare();
session.state.addListener(() {
  print(session.state.value);
});

session.dispose();
```

设备墙或需要同时嵌入多个画面的宿主，应通过 `ScrcpySessionManager` 统一持有 Session：

```dart
final sessions = ScrcpySessionManager(
  client: client,
  maxSessions: 16,
);

final mainScreen = sessions.create(
  const ScrcpySessionConfiguration(deviceSerial: 'device-a'),
  id: 'device-a-main',
);
final appScreen = sessions.create(
  const ScrcpySessionConfiguration(
    deviceSerial: 'device-a',
    displaySource: ScrcpyDisplaySource.virtual(
      width: 1280,
      height: 720,
      dpi: 240,
    ),
  ),
);

final connection = await sessions.start(mainScreen.id);
sessions.focus(appScreen.id);

final deviceSessions = sessions.sessionsForDevice('device-a');
await sessions.remove(mainScreen.id);
await sessions.close();
sessions.dispose();
```

管理器拥有 `ScrcpySession` 和连接生命周期，并公开只读的 `ScrcpyManagedSession`；宿主仍拥有从连接创建的视频、音频和剪贴板 Controller，移除 Session 前应先释放这些 Controller。`sessionsByDevice` 提供“设备 → Session”层级，默认总上限为 16，也可以由宿主调整或设为 `null`。

`displaySource` 默认是主屏，也可以选择已有显示或声明一个新虚拟显示：

```dart
const source = ScrcpyDisplaySource.virtual(
  width: 1280,
  height: 720,
  dpi: 240,
  systemDecorations: false,
  closePolicy: ScrcpyVirtualDisplayClosePolicy.moveContentToMainDisplay,
  imePolicy: ScrcpyDisplayImePolicy.local,
  keepActive: true,
  launchApplication: ScrcpyApplicationLaunch(
    'com.example.app',
    forceStopBeforeStart: true,
  ),
);
```

应用启动通过 scrcpy `START_APP` 控制消息完成，不会作为未知参数传给 server。Demo 的应用列表可直接创建独立虚拟屏 Session；关闭页面会停止 Session 并销毁虚拟显示，选择迁移内容策略时则由 Android 将内容移回主屏。

虚拟显示启用 `flexDisplay` 后，可以在 Session 运行期间切换应用和尺寸：

```dart
final input = connection.input!;
await input.startApplication(
  const ScrcpyApplicationLaunch('com.example.second'),
);
await input.resizeDisplay(width: 1920, height: 1080);
```

设备编码器可以在创建 session 前动态探测：

```dart
final capabilities = await client.probeVideoCapabilities(deviceSerial);
final h264Encoders = capabilities.forCodec(ScrcpyVideoCodec.h264);
```

探测结果区分硬件/软件、vendor 和 alias 编码器。当前 Windows Native Texture 后端仅声明 H.264 解码能力；设备即使具有 H.265/AV1 编码器，选择后也会得到明确的 `unsupportedCapability`，不会以黑屏代替错误。

音频传输默认关闭，不影响原有纯视频 Session。需要原始 Opus 包时显式启用：

```dart
final session = client.createSession(
  const ScrcpySessionConfiguration(
    deviceSerial: '实际序列号只保存在内存',
    audioEnabled: true,
    audioRequired: false, // 不可用时保留视频；true 则启动失败并清理
    audio: ScrcpyAudioOptions(codec: ScrcpyAudioCodec.opus),
  ),
);
final connection = await session.start();
final audio = connection.audio!;
final codec = await audio.codec; // null 表示设备端禁用或不可用
audio.packets.listen((packet) {
  // packet.data 是编码 payload，PTS 保留 scrcpy server 原值。
});
```

编码音频传输层与 Windows 原生播放、音量、静音及多窗口焦点管理均已公开。

`ScrcpyAudioOptions` 默认使用 `ScrcpyAudioSource.automatic`：Android 11 选择 `output`，Android 12 及以上选择 `playback`，无法取得系统版本时保守选择 `output`。宿主可以显式指定音源覆盖自动策略；`duplicateOnDevice` 仍要求显式选择 `playback`。虚拟显示工作台固定使用 `playback`，避免部分厂商把虚拟屏 `output` 路由同时复制到手机。

Windows 可直接创建原生播放器；停止播放器不会关闭共享的视频连接：

```dart
final player = createNativeScrcpyAudioController(
  connection.audio!,
  bitRate: 128000,
);
await player.start();
await player.setVolume(0.5);
await player.setMuted(true);
await player.setMuted(false);
await player.stop();
player.dispose();
```

通过 `player.value` 可观察播放状态、编码包数、传输字节、解码包、已播放/丢弃缓冲和当前缓冲字节。当前只支持 Opus。多个播放器可注册到 `ScrcpyAudioFocusManager`；请求焦点时只恢复目标播放器的用户静音状态，其余播放器保持静音，断流或播放错误会自动释放焦点。

`prepare()` 只确认设备存在且状态可用；`start()` 才建立 server、socket 和 forward。Player、texture 等平台 Controller 由宿主独立持有，不改变 Session 的所有权模型。

## 视频组件

```dart
ScrcpyVideoView(
  controller: videoController,
  fit: BoxFit.contain,
  placeholder: const Center(child: CircularProgressIndicator()),
)
```

`ScrcpyVideoController` 隐藏平台解码器和 Texture 创建细节，通过 `ScrcpyVideoState` 暴露播放状态、texture ID、视频尺寸和错误。

## 输入覆盖层

```dart
ScrcpyInputLayer(
  controller: inputController,
  child: ScrcpyVideoView(controller: videoController),
)
```

输入层公开归一化 pointer、滚轮、按键和文本接口，并已在内部处理 contain/cover 黑边、旋转、DPI 和动态视频尺寸映射，不要求宿主重写 UI。鼠标默认与 scrcpy 桌面端一致：左键注入触摸，中键发送 Home，右键发送 `BACK_OR_SCREEN_ON`（亮屏时返回，熄屏时点亮）。默认将靠近视频四边 2% 范围的鼠标按下吸附到首/末物理像素，以便 Android 边缘手势识别；宿主可通过 `gestureEdgeThreshold` 调整或设为 0 关闭。`ScrcpyGestureSimulator` 可生成归一化双指缩放序列。

## 剪贴板

```dart
final clipboard = ScrcpyClipboardSynchronizer(connection.input!);
await clipboard.start(); // 开启双向同步

await clipboard.pushHostToDevice(paste: true);
await clipboard.pullDeviceToHost(copyKey: ScrcpyCopyKey.copy);

await clipboard.stop();
```

`ScrcpyInputController` 也公开 `clipboardChanges`、`requestClipboard()` 和 `setClipboard()`，宿主可以只使用协议层而不启用系统剪贴板同步。内置 server 使用 `clipboard_autosync=false`，由插件统一处理轮询和回环抑制。剪贴板正文不会写入日志。

## 错误与日志

- `AdbException`、`ScrcpyException` 都包含机器可读错误码。
- `ScrcpyLogRecord` 包含级别、来源、可选 session ID 和结构化字段。
- 设备标识使用 `AdbDevice.redactedSerial` 写入 UI/日志。
- 配对地址、配对码及 typed ADB 命令中的设备序列号不会进入 process 后端诊断参数。

