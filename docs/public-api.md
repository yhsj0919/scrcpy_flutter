# P0 公开 API 基线

更新于 2026-08-31。宿主应用只导入：

```dart
import 'package:scrcpy_flutter/scrcpy_flutter.dart';
```

不得导入 `package:scrcpy_flutter/src/...`，也不需要直接依赖 process、平台解码器或 scrcpy 上游内部对象。

## 初始化与能力查询

```dart
final client = createDefaultScrcpyClient();
final capabilities = client.capabilities;
```

如宿主需要使用自己校验过的资源，可显式覆盖路径：

```dart
final client = createDefaultScrcpyClient(
  adbExecutablePath: r'C:\managed-tools\adb.exe',
  scrcpyServerPath: r'C:\managed-tools\scrcpy-server-v4.1',
);
```

Windows 默认 Client 使用随插件分发的官方 ADB。`capabilities.video` 和 `capabilities.control` 在真实后端接入前保持 `false`，宿主应据此禁用入口。

## 设备发现

```dart
final devices = await client.discoverDevices();
for (final device in devices) {
  print('${device.redactedSerial}: ${device.state.name}');
}
```

ADB 领域能力位于独立的 `adb_client` package，通过主入口重导出。连接、配对、Wireless Debugging mDNS 发现、shell、sync、包管理和 forward 均有 typed interface，宿主不拼接 shell 字符串。

`ScrcpyClient.discoverDevices()` 会合并 `adb devices -l` 与 mDNS connect 服务。在线设备优先；尚未在线的已配对设备使用 `AdbDeviceState.paired`，并通过 `lastSeenAt` 提供最后发现时间。pairing 广播只用于配对流程，不进入设备列表。

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

设备编码器可以在创建 session 前动态探测：

```dart
final capabilities = await client.probeVideoCapabilities(deviceSerial);
final h264Encoders = capabilities.forCodec(ScrcpyVideoCodec.h264);
```

探测结果区分硬件/软件、vendor 和 alias 编码器。当前 Windows Native Texture 后端仅声明 H.264 解码能力；设备即使具有 H.265/AV1 编码器，选择后也会得到明确的 `unsupportedCapability`，不会以黑屏代替错误。

P0 的 `prepare()` 仅确认设备存在且状态可用。P1/P2 将在同一生命周期后面接入 server、socket、forward、Player 和 texture，不改变宿主的基本所有权模型。

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

输入层公开归一化 pointer、滚轮、按键和文本接口，并已在内部处理 contain/cover 黑边、旋转、DPI 和动态视频尺寸映射，不要求宿主重写 UI。`ScrcpyGestureSimulator` 可生成归一化双指缩放序列。

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
