# scrcpy_flutter 完整使用指南

本文面向两类读者：准备把设备控制能力嵌入 Flutter 应用的接入方，以及准备继续拆分仓库包结构的维护者。内容以当前仓库代码为准，示例应用只用于展示组合方式，不代表所有界面和业务策略都属于插件。

> 当前主要可运行平台是 Windows 主机控制 Android 设备。Android、iOS、macOS、Linux、Web 和鸿蒙主机端尚未形成可交付实现；“鸿蒙支持”当前目标是未来由鸿蒙应用控制 Android 设备，不是控制鸿蒙设备。

## 1. 能力边界

当前仓库分为三层：

| 层级 | 当前载体 | 负责内容 | 不负责内容 |
| --- | --- | --- | --- |
| ADB 基础层 | `packages/adb_client` | 设备发现、USB/网络连接、无线配对、shell、文件、应用、设备信息、运行状态、批量任务 | 视频、音频、实时输入、Flutter UI |
| ADB 桌面实现层 | `packages/adb_client_process` | 通过随包或外部 `adb` 进程实现 ADB 接口 | 业务页面、scrcpy 会话 |
| scrcpy 插件层 | 根包 `scrcpy_flutter` | server 部署、会话、视频、音频、输入、剪贴板、虚拟屏、Flutter Texture、指标 | 设备墙布局、选择哪些窗口联动、业务权限和产品策略 |
| 示例/使用端 | `example` | 设备列表、详情、文件页、工作台、设备墙、音频焦点、批量控制、触摸广播等组合示例 | 稳定公共 API 承诺 |

依赖方向是：

```text
scrcpy_flutter  ──依赖──>  adb_client  <──实现──  adb_client_process
       ↑
 Flutter 宿主应用（自行组织单画面、工作台和设备墙）
```

关键原则：

- ADB 功能可以独立增长，不应要求修改 scrcpy 会话层。
- `scrcpy_flutter` 可以依赖 ADB 抽象完成 server 部署、端口转发和设备查询。
- `device_wall.dart`、窗口网格、选中状态、跨会话广播、音频焦点策略属于使用端。
- 接入方只导入公开入口，不导入任何 `src` 文件。

```dart
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';
```

## 2. 运行资源与初始化

### 2.1 添加依赖

项目当前为内部开发版本，尚未发布到 pub.dev。仓库内 Example 使用本地路径；外部宿主可先通过 Git 或固定目录引用：

```yaml
dependencies:
  flutter:
    sdk: flutter
  scrcpy_flutter:
    path: ../scrcpy_flutter
  adb_client:
    path: ../scrcpy_flutter/packages/adb_client
```

如果宿主只需要 ADB 工具箱，可以只依赖 `adb_client`，并选择一个实现它的 backend；若使用根插件的默认 Windows Client，宿主不必直接操作 `adb_client_process`。

运行仓库自带 Demo：

```powershell
cd example
flutter pub get
flutter run -d windows
```

Android 设备需要开启开发者选项和 USB 调试，并在设备上确认当前电脑的调试授权。网络设备还需要先完成无线调试配对/连接，或者由有权限的设备方案预先启用网络 ADB。

### 2.2 默认初始化

```dart
final scrcpy = createDefaultScrcpyManager();
final adb = scrcpy.adb;
```

最短的投屏代码只有创建 Session 和放置 View：

```dart
final session = await scrcpy.createSession(
  deviceSerial: device.serial,
  audioEnabled: true,
);

ScrcpyView(session: session);
```

`ScrcpySession` 自动持有连接、视频解码器、音频播放器、输入通道及重连后的替换资源。普通接入方不需要直接创建 `ScrcpyVideoConnection`、`ScrcpyVideoController` 或 `ScrcpyAudioController`。

截取当前解码画面并保存 PNG：

```dart
final screenshot = await session.captureFrame();
await screenshot.saveToFile(r'D:\captures\device.png');
```

该操作复用当前解码帧，不会暂停画面或重建 Session。也可直接使用 `screenshot.pngBytes` 交给宿主自己的存储或上传逻辑。

Windows 构建默认随插件分发固定版本的 ADB、其运行库和匹配版本的 `scrcpy-server`，宿主机器不需要预装 Android SDK，也不依赖系统 `PATH`。

如产品需要自行托管和校验二进制，可以覆盖路径：

```dart
final scrcpy = createDefaultScrcpyManager(
  adbExecutablePath: r'C:\managed-tools\adb.exe',
  scrcpyServerPath: r'C:\managed-tools\scrcpy-server-v4.1',
);
```

可通过运行时信息确认实际使用的资源路径、版本和校验值。发布产品时应同时保留第三方许可证，具体来源见 [third-party-components.md](third-party-components.md)。

### 2.3 高级能力查询

```dart
import 'package:scrcpy_flutter/scrcpy_advanced.dart';

final client = createDefaultScrcpyClient();
final capabilities = client.capabilities;
```

这属于自定义后端或诊断场景。普通接入不需要先查询全局能力；不支持的编解码器或音频能力会通过结构化错误报告。`ScrcpyCapabilities` 只描述 scrcpy 视频和实时控制能力，设备发现、USB、网络连接和配对仍属于 ADB。

Windows 使用随插件分发的官方 `adb.exe`。Android 将使用插件原生后端，
不再提供切换到纯 Dart ADB 的运行参数。设备发现功能延后接入。

## 3. ADB 基础工具箱

### 3.1 一次性发现设备

```dart
final devices = await adb.discoverDevices();
for (final device in devices) {
  print('${device.redactedSerial} ${device.state.name} ${device.model}');
}
```

`discoverDevices()` 合并以下来源：

- `adb devices -l` 中的 USB 和已连接网络设备；
- Wireless Debugging 的 mDNS connect 服务；
- 已发现但尚未连接的配对设备以 `AdbDeviceState.paired` 表示。

常见状态包括 `device`、`unauthorized`、`offline`、`recovery`、`bootloader`、`sideload`、`noPermissions`、`paired` 和 `unknown`。只有 `device.isReady == true` 时才适合启动管理和投屏操作。

Android 宿主可以在默认 ADB 后端支持时读取 USB Host 状态：

```dart
if (client.adbClient case final AdbUsbHostProvider usbHost) {
  final status = await usbHost.getUsbHostStatus();
  if (status.state == AdbUsbHostState.permissionDenied) {
    await usbHost.getUsbHostStatus(requestPermission: true);
  }
}
```

`noDevice` 表示本机没有枚举到 USB 外设；两台 Type-C 手机已经连接时，这通常意味着 USB Host/Peripheral 角色与预期相反。`noAdbInterface` 表示本机已经成为 Host 并看到 USB 设备，但目标没有暴露 ADB 接口，需检查 USB 调试、默认 USB 功能或厂商换机应用。普通第三方应用不能通过该接口强制交换 USB 数据角色。

### 3.2 持续监听设备变化

```dart
final subscription = adb.watchDevices(
  interval: const Duration(seconds: 2),
).listen((snapshot) {
  // 根据 snapshot 更新设备列表。
});

// 页面销毁时：
await subscription.cancel();
```

`watchDevices()` 在首个订阅建立时立即查询一次，之后自动轮询；取消订阅会停止轮询并释放内部 Monitor，不需要额外调用 `start()` 或 `close()`。默认只发送首帧和发生增删/状态变化的快照；如每个采样周期都需要结果，可传入 `emitOnlyChanges: false`。

监听适用于设备插拔、授权状态变化以及网络设备出现/消失。UI 应以序列号为稳定键，不要以列表下标持有设备。多个页面需要共享一份监听结果时，应由使用端 Store 订阅一次并向页面分发，避免每个页面各启一个 ADB 轮询。

需要主动 `refresh()`、暂停后恢复或精确管理生命周期时，仍可直接使用高级接口 `AdbDeviceMonitor`。

### 3.3 网络连接与断开

```dart
final endpoint = AdbEndpoint(host: '192.168.1.20', port: 5555);
await adb.connect(endpoint);
await adb.disconnect(endpoint);
```

这要求目标设备已经开启可用的网络 ADB。VPN/组网只能解决网络可达性，不能替代 Android 的调试授权，也不能自动打开设备的网络调试开关。

### 3.4 Wireless Debugging 验证码配对

```dart
final pairingEndpoint = AdbEndpoint(host: '192.168.1.20', port: 37123);
final connectedEndpoint = await adb.pairAndConnect(
  pairingEndpoint,
  '123456',
);
```

配对端口与连接端口不是同一个固定端口。`pairAndConnect()` 配对成功后会等待同一主机的 `_adb-tls-connect` mDNS 服务并自动连接；返回 `null` 表示配对已成功，但在限定时间内未发现连接端口。已知连接端口时可传入 `connectionEndpoint` 跳过发现。仅需配对而不连接时仍可直接调用 `pair()`。

需要让配对界面自动更新时直接监听，不需要自行创建定时器：

```dart
final subscription = adb.watchMdnsServices().listen((snapshot) {
  final pairing = snapshot.services.where(
    (service) => service.type == AdbMdnsServiceType.pairing,
  );
  final connect = snapshot.services.where(
    (service) => service.type == AdbMdnsServiceType.connect,
  );
  // 更新“待配对”和“可连接”列表。
});

await subscription.cancel();
```

`watchMdnsServices()` 只在后端实现设备发现后产生结果。设备发现不属于当前 Android 主链路的迁移范围；未实现的平台返回空快照。mDNS 只减少 IP 和动态端口输入，配对码和授权仍由 Android 控制。

### 3.5 取消耗时操作

```dart
final token = AdbCancellationToken();
final future = adb.discoverDevices(cancellationToken: token);

// 用户点击取消：
token.cancel();
await future;
```

文件传输、设备查询、应用操作和批量任务均应把 token 传到底层。取消后通常抛出 `AdbException`，错误码为 `AdbErrorCode.cancelled`。

## 4. 设备信息与运行状态

### 4.1 基本详情

```dart
final details = await adb.getDeviceDetails(device);

print(details.brand);
print(details.manufacturer);
print(details.model);
print(details.androidVersion);
print(details.sdkLevel);
print(details.abi);
print('${details.screenWidth}x${details.screenHeight}');
print(details.densityDpi);
print(details.batteryLevel);
print(details.batteryTemperatureCelsius);
print(details.storageTotalBytes);
print(details.storageAvailableBytes);
print(details.uptime);
```

详情由多个独立查询组成。某一项失败不会使全部详情失效，失败原因放在 `details.unavailable`，UI 应允许字段显示“不可用”。

### 4.2 设备运行状态

```dart
final statusMonitor = adb.status(
  device.serial,
  interval: const Duration(seconds: 5),
);

final subscription = statusMonitor.statuses.listen((status) {
  // CPU、设备 GPU、内存、存储、网络、电池、前台应用、应用进程等。
});

final first = await statusMonitor.start();

// 需要立即刷新时：
final latest = await statusMonitor.refresh();

// 页面退出：
await subscription.cancel();
await statusMonitor.close();
```

当前状态能力包括：

- 设备整体 CPU 使用率；
- 设备整体 GPU 使用率和检测到的 GPU 驱动来源；
- 内存用量、存储余量；
- 累计网络接收/发送量；
- 电池电量和温度；
- 前台应用包名；
- 前台应用 PID、CPU、PSS、RSS；
- 在设备提供对应统计时，前台应用 GPU 和显存。

PSS 更接近进程应承担的实际内存份额；RSS 是当前驻留在物理内存中的页面总量，会重复计入共享页面。设备或厂商内核不提供某项数据时，该项应显示为未知，而不是显示“设备不支持”。GPU 为 `0` 是有效采样值，表示采样周期内没有可见占用。

刷新周期由 `interval` 指定。设备墙中设备很多时应适当降低频率，避免大量 `dumpsys`/`procfs` 查询与音视频链路争抢资源。

## 5. 应用管理

### 5.1 获取所有应用

```dart
final applications = adb.applications(device.serial);
final apps = await applications.listApplications();

final userApps = apps.where(
  (app) => app.type == AdbApplicationType.user,
);
```

返回信息包括包名、APK 路径、UID、版本号、用户/系统分类和可启动状态等。纯 ADB 在很多设备上只能稳定获得包名，不能稳定取得本地化应用名称。

若需要尽可能补全显示名称，可使用 scrcpy 客户端提供的增强查询：

```dart
final appsWithLabels = await scrcpy.listApplications(device.serial);
```

此方法会借助随包的 scrcpy server 获取 label。它是当前最明显的跨层组合点：包信息属于 ADB，label 增强依赖 scrcpy server；未来分包时可将其放入可选适配/聚合层。

### 5.2 启动和停止应用

```dart
await applications.startApplication('com.example.app');
await applications.startApplication(
  'com.example.app',
  forceStopFirst: true,
);
await applications.stopApplication('com.example.app');
```

这里的 ADB 启动发生在 Android 默认显示策略选择的屏幕上。若要明确在某个 scrcpy 虚拟屏中启动应用，应使用第 10 节的 scrcpy 控制消息。

### 5.3 安装和卸载

底层 `AdbClient` 提供 typed package API，支持 APK 安装、覆盖安装、卸载和保留数据。需要多设备执行时优先使用批量任务。

## 6. 文件管理

```dart
final files = adb.files(device.serial);

final entries = await files.listDirectory('/sdcard/Download');
await files.createDirectory('/sdcard/Download/new-folder');
await files.createDirectory('/sdcard/a/b/c', recursive: true);

await files.push(
  r'C:\temp\demo.apk',
  '/sdcard/Download/demo.apk',
  overwrite: true,
);
await files.pull(
  '/sdcard/Download/report.txt',
  r'C:\temp\report.txt',
);

await files.rename(
  '/sdcard/Download/old.txt',
  '/sdcard/Download/new.txt',
);
await files.delete('/sdcard/Download/new.txt');
await files.delete('/sdcard/Download/folder', recursive: true);
```

远端路径必须是 Android 绝对路径。删除 `/` 会被拒绝。具体目录能否读写仍取决于 Android 版本、设备权限和 shell 用户权限；插件不会绕过 Android 沙箱。

## 7. ADB 批量任务

### 7.1 批量安装

```dart
final task = adb.batchPackages.installTask(
  deviceSerials: selectedSerials,
  apkPath: r'C:\packages\app.apk',
  replaceExisting: true,
  maxConcurrency: 3,
  itemTimeout: const Duration(minutes: 5),
  maxAttempts: 2,
);

final subscription = task.snapshots.listen((snapshot) {
  for (final item in snapshot.items.values) {
    print('${item.target}: ${item.state.name} (${item.attempts})');
  }
});

final result = await task.start();
await subscription.cancel();
```

### 7.2 批量卸载

```dart
final task = adb.batchPackages.uninstallTask(
  deviceSerials: selectedSerials,
  packageName: 'com.example.app',
  keepData: false,
);
await task.start();
```

任务支持：

- 并发上限；
- 单设备超时；
- 自动重试；
- `pause()`：不再领取新的排队项，已运行项继续完成；
- `resume()`：恢复领取；
- `cancel()`：取消活动 token，并把未运行项标为取消；
- 每设备状态 `queued`、`running`、`succeeded`、`failed`、`timedOut`、`cancelled`。

设备墙中的批量启动/停止、批量按键和批量触摸属于业务编排，可用通用 `AdbBatchTask` 或 scrcpy 输入原语组合，不属于设备墙库组件。

## 8. 创建 scrcpy 会话

本节先介绍推荐的高层入口，后半部分的 `prepare()`、Connection 和原生 Controller 用法只供需要协议级控制的高级接入方使用。

### 8.1 推荐：开箱即用会话

```dart
final main = await scrcpy.createSession(
  deviceSerial: device.serial,
  audioEnabled: true,
);

final virtual = await scrcpy.createSession(
  deviceSerial: device.serial,
  display: ScrcpyDisplay.virtual(
    width: 720,
    height: 1280,
    dpi: 240,
    application: 'com.example.app',
  ),
);
```

所有会话采用相同的 View：

```dart
ScrcpyView(
  session: virtual,
  fit: BoxFit.contain,
  interactive: true,
);
```

循环展示不需要接触底层连接：

```dart
GridView.builder(
  itemCount: scrcpy.sessions.length,
  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: 4,
  ),
  itemBuilder: (context, index) => ScrcpyView(
    session: scrcpy.sessions[index],
  ),
);
```

删除 Session 必须由拥有它的 Manager 明确执行；View 离开 Widget Tree 不会停止投屏：

```dart
await scrcpy.removeSession(session.id);

// 应用整体退出：
await scrcpy.close();
scrcpy.dispose();
```

### 8.2 高级：直接管理底层会话

```dart
final session = scrcpy.createSession(
  ScrcpySessionConfiguration(
    deviceSerial: device.serial,
    video: const ScrcpyVideoOptions(
      maxSize: 1920,
      maxFps: 60,
      bitRate: 8 * 1000 * 1000,
      codec: ScrcpyVideoCodec.h264,
    ),
    controlEnabled: true,
    audioEnabled: true,
    audioRequired: false,
    reconnectPolicy: const ScrcpyReconnectPolicy(
      maxAttempts: 3,
    ),
  ),
);

session.state.addListener(() {
  print(session.state.value);
});

await session.prepare();
final connection = await session.start();
```

会话状态包括 `idle`、`preparing`、`ready`、`starting`、`streaming`、`stopping`、`disconnected`、`reconnecting`、`error` 和 `disposed`。

`prepare()` 负责设备和 server 准备；`start()` 建立实际音视频/控制连接。可以直接调用 `start()`，它会完成必要准备，但拆开调用更利于 UI 显示进度和错误。

### 8.3 视频参数

`ScrcpyVideoOptions` 当前支持：

| 参数 | 默认值 | 含义 |
| --- | ---: | --- |
| `maxSize` | 1920 | 编码长边上限；`0` 表示不限制 |
| `maxFps` | 60 | 最大帧率 |
| `bitRate` | 8 Mbps | 目标视频码率 |
| `codec` | H.264 | H.264、H.265 或 AV1 请求 |
| `encoder` | null | 指定 Android MediaCodec 编码器；空值由 scrcpy 选择 |

虽然协议层能表达 H.265/AV1，当前 Windows 原生 Flutter Texture 解码链路以 H.264 为已实现、已验证路径。接入前可调用编码能力探测，不要仅依据设备宣称的 codec 决定桌面端是否可播。

修改这些启动参数需要重新建立 scrcpy 会话。当前没有无缝运行时切换码率、帧率和 codec 的公开能力。

### 8.4 自动重连

```dart
const policy = ScrcpyReconnectPolicy(
  maxAttempts: 5,
  initialDelay: Duration(seconds: 1),
  maxDelay: Duration(seconds: 8),
  multiplier: 2,
);
```

USB 短暂掉线时会按退避策略重建连接。重连成功后会产生新的 `ScrcpyVideoConnection`：

```dart
final subscription = session.reconnectedConnections.listen((newConnection) {
  // 旧 connection 上的音频、视频控制器必须替换为基于 newConnection 的实例。
});
```

不能继续向旧连接的 input socket 写数据；它已关闭。UI 和广播控制器应检查当前输入通道是否可用。

## 9. 多会话管理

```dart
final scrcpy = createDefaultScrcpyManager(maxSessions: 16);
final session = await scrcpy.createSession(
  deviceSerial: device.serial,
  id: '${device.serial}:main',
);

// 任意布局中直接展示。
ScrcpyView(session: session);

await scrcpy.removeSession(session.id);
```

管理器提供：

- `sessions`：全部只读会话视图；
- `sessionsForDevice(serial)`：某个物理设备的所有会话；
- `sessionsForDevice(serial)`：按设备查询；
- `createSession`、`createVirtualSession`、`removeSession`；
- `createGroup`：建立带主控的批量控制组；
- 最大会话数限制。

管理器持有 Session 生命周期，Session 内部持有连接、音视频控制器和输入通道。接入方不再手动拼装或替换 Controller。

## 10. 主屏、已有屏幕与虚拟屏

### 10.1 主屏

```dart
displaySource: const ScrcpyDisplaySource.main(),
```

显示和控制 Android 主显示屏。

### 10.2 连接已有 Display ID

```dart
displaySource: const ScrcpyDisplaySource.existing(
  22,
  imePolicy: ScrcpyDisplayImePolicy.local,
),
```

`Display 22` 是 Android DisplayManager 分配的显示 ID，不是“ADB 投屏 ID”。它通常只在该次系统运行或虚拟屏生命周期内有意义，不应持久化为跨重启稳定标识。

### 10.3 创建虚拟屏并启动应用

```dart
displaySource: const ScrcpyDisplaySource.virtual(
  width: 720,
  height: 1280,
  dpi: 240,
  systemDecorations: true,
  closePolicy: ScrcpyVirtualDisplayClosePolicy.destroyContent,
  imePolicy: ScrcpyDisplayImePolicy.local,
  keepActive: true,
  flexDisplay: true,
  launchApplication: ScrcpyApplicationLaunch(
    'com.example.app',
    forceStopBeforeStart: false,
  ),
),
```

参数说明：

- `width`/`height` 是 Android 虚拟显示的真实像素尺寸，不是 Flutter 预览框尺寸；
- `dpi` 决定 Android UI 密度；
- `systemDecorations` 请求在虚拟屏显示系统导航/状态装饰，厂商系统可能忽略；
- `closePolicy` 决定关闭虚拟屏时销毁内容还是移回主屏；
- `imePolicy` 决定输入法显示策略；
- `keepActive` 请求虚拟屏保持活跃；
- `flexDisplay` 允许 scrcpy/系统配合应用方向调整显示；
- `launchApplication` 在该显示中启动指定应用。

当前 Demo 的产品默认值是“优先竖屏”：从设备物理尺寸取方向，必要时降低分辨率，但不会因为预览框是横向就把虚拟屏创建成横屏。预览框变化和虚拟屏像素变化是两个不同概念。

### 10.4 运行时启动应用

```dart
await connection.input!.startApplication(
  const ScrcpyApplicationLaunch('com.example.app'),
);
```

该控制消息在当前会话对应的显示中启动应用，适合“任意应用在任意虚拟屏打开”。

### 10.5 运行时调整虚拟屏尺寸

```dart
await connection.input!.resizeDisplay(width: 900, height: 1600);
```

调整的是 Android Display 尺寸，不等同于 Flutter Widget 缩放。设备/应用可能发生 configuration change、Activity 重建或短暂动画。保持方向且只改变分辨率，通常比横竖方向切换更平滑。

### 10.6 预览框自适应

```dart
final adaptive = ScrcpyAdaptiveDisplayController(
  input: connection.input!,
  // 其余节流、上限等参数按构造器配置。
);

adaptive.updatePreview(previewSize);
```

“自适应”不是强制 1:1 像素显示。它表示根据预览区域计算合适的虚拟显示尺寸，并受最大分辨率、节流和显著变化阈值约束：预览框小于上限时可按预览尺寸处理，大于上限时限制到最大尺寸。普通视频显示仍可使用 `BoxFit.contain` 缩放到 Widget。

## 11. 视频播放与 Flutter 渲染

```dart
final video = createNativeScrcpyVideoController(connection);
await video.start();

ScrcpyVideoView(
  controller: video,
  fit: BoxFit.contain,
  placeholder: const ColoredBox(color: Color(0xFF101116)),
);
```

当前 Windows 路径是：

```text
scrcpy server 编码包
  → Dart 拆包并保留 codec/session/PTS/keyframe 元数据
  → Windows Media Foundation 硬件优先解码
  → 原生 BGRA Texture
  → Flutter Texture Widget
```

它不依赖 FVP/VLC，也不把每帧像素复制到 Dart 后再绘制。Flutter 负责布局、裁剪和叠加控制层，原生插件负责低延迟解码和 Texture 更新。

`ScrcpyVideoController.value` 可用于观察 `idle`、`buffering`、`ready`、`ended`、`error`、帧数、尺寸等状态。花屏、偏色等问题应优先检查编码包边界、stride/像素格式和 Texture 上传，不应在 UI 上打颜色补丁。

## 12. 音频采集与播放

### 12.1 配置音频

```dart
final session = scrcpy.createSession(
  ScrcpySessionConfiguration(
    deviceSerial: device.serial,
    audioEnabled: true,
    audioRequired: false,
    audio: const ScrcpyAudioOptions(
      codec: ScrcpyAudioCodec.opus,
      bitRate: 128000,
      source: ScrcpyAudioSource.automatic,
      duplicateOnDevice: false,
    ),
  ),
);
```

`audioRequired: false` 表示音频不可用时视频仍继续；为 `true` 时音频初始化失败会使整个会话失败。

音频源：

- `automatic`：Android 12 及以上使用 `playback`，Android 11 或 SDK 未知时使用 `output`；
- `output`：系统输出捕获，Android 11 兼容路径可能触发系统确认弹窗；
- `playback`：Android Playback Capture；
- `duplicateOnDevice`：仅适用于 `playback`，允许设备端同时发声。

Android 11 的具体行为受厂商系统影响。当前“安卓 11 开发板音频确认/捕获”仍是待集中验证项；不应把一次 `unsupportedCapability` 简化为所有 Android 11 均不支持。

### 12.2 播放

```dart
final audioStream = connection.audio;
if (audioStream != null) {
  final audio = createNativeScrcpyAudioController(audioStream);
  await audio.start();
  await audio.setVolume(0.8);
  await audio.setMuted(false);
}
```

当前 Windows 使用内置 libopus 解码并输出到电脑。`duplicateOnDevice == false` 时目标是电脑播放而手机静音，但最终路由仍受 Android 版本、音频源和厂商实现影响。

### 12.3 音频焦点

设备墙通常只允许一个窗口发声。插件提供通用焦点协调器，焦点选择策略由应用决定：

```dart
final focus = ScrcpyAudioFocusManager();

await focus.register(id: windowId, controller: audioController);
await focus.requestFocus(windowId);
await focus.setMuted(windowId, true);
await focus.unregister(windowId);

await focus.close();
focus.dispose();
```

窗口重连会创建新的音频控制器，应先注销旧参与者，再注册新控制器。调用前可用 `isRegistered(id)` 检查，或用 `tryRequestFocus(id)` 避免 UI 指针事件抛出未知参与者异常。

虚拟屏音频不是天然按 Display 隔离的独立流。它本质上仍受同一物理 Android 设备的采集/路由能力约束。Demo 对同设备多窗口做了共享与焦点编排；这类策略属于使用端，不是 scrcpy 协议保证。

## 13. 鼠标、触摸和键盘

### 13.1 覆盖 Flutter 输入层

```dart
ValueListenableBuilder<ScrcpyVideoState>(
  valueListenable: video,
  builder: (context, state, _) {
    final videoSize = state.width != null && state.height != null
        ? Size(state.width!.toDouble(), state.height!.toDouble())
        : null;
    return ScrcpyInputLayer(
      controller: connection.input!,
      videoSize: videoSize,
      fit: BoxFit.contain,
      enabled: true,
      autofocus: true,
      captureAllKeys: false,
      blockHostGestures: true,
      gestureEdgeThreshold: 0.02,
      child: ScrcpyVideoView(
        controller: video,
        fit: BoxFit.contain,
      ),
    );
  },
);
```

输入层必须与视频使用相同的 `fit` 和 alignment，坐标才会正确扣除黑边并映射到设备视频尺寸。虚拟屏 resize/旋转后，应使用最新解码尺寸，不能继续使用旧宽高。

`blockHostGestures` 默认为 `true`。在投屏内上下拖动、触摸或滚轮操作时，输入层会取得手势所有权，外层 `ListView`、页面滑动和宿主手势不会同时触发。如果宿主有意在视频上覆盖自己的导航手势，可以设为 `false`。使用开箱即用的 `ScrcpyView` 或 `ScrcpyGroupView` 时也可直接传入该参数。

桌面鼠标约定与 scrcpy 对齐：

- 左键：触摸/确定；
- 中键：Home；
- 右键：Back；设备锁屏时使用 Back-or-screen-on 语义点亮屏幕。

正常系统组合键（如 Ctrl、Alt、Meta 参与的快捷键）默认留给桌面系统，不全部拦截。普通键盘输入在输入层获得焦点时映射为 Android 按键或文本。

### 13.2 直接发送输入

```dart
await connection.input!.sendPointer(
  const ScrcpyPointerEvent(
    pointerId: ScrcpyPointerId.mouse,
    action: ScrcpyPointerAction.down,
    normalizedX: 0.25,
    normalizedY: 0.5,
    buttons: 1, // Flutter 主鼠标键位掩码。
  ),
);

await connection.input!.sendKey(keyCode: 3, down: true); // HOME 示例
await connection.input!.sendText('hello');
```

每个 pointer 必须形成完整且唯一的 down → move → up/cancel 生命周期。重复 down、丢失 up 或把多个业务窗口的 pointer ID 混用，会触发 server 的 `Too many pointers for touch event`，严重时表现为后续触摸失效。

连接断开或重连后，旧 input 不可继续使用。实现批量触摸时，每个目标会话必须持有独立 pointer 状态，并在不可用时从广播目标中移除。

### 13.3 边缘手势与鼠标越界

小米等全面屏设备的返回/多任务依赖从显示边缘开始的完整手势。Flutter 预览存在黑边和缩放时，必须先映射到实际内容矩形。鼠标拖出 Widget 后是否继续捕获、钳制坐标或取消手势是产品体验策略；当前没有把“越界立即发送 up”固化为插件规则。

### 13.4 多点手势

```dart
final gestures = ScrcpyGestureSimulator(connection.input!);
await gestures.pinch(
  center: const Offset(500, 800),
  startDistance: 100,
  endDistance: 250,
  steps: 12,
);
```

模拟器基于相同输入原语发送多 pointer 序列。业务端应串行化同一会话的手势，避免真实鼠标和模拟手势同时占用相同 pointer。

## 14. 剪贴板

```dart
final clipboard = ScrcpyClipboardSynchronizer(connection.input!);

await clipboard.start();
await clipboard.pushHostToDevice(paste: false);
final text = await clipboard.pullDeviceToHost();

await clipboard.stop();
```

同步器支持设备剪贴板变化监听、主机到设备推送、设备到主机拉取和去重。宿主可注入自己的剪贴板实现；默认 Flutter 实现适合普通桌面应用。

剪贴板可能包含隐私数据。设备墙产品应明确当前操作设备，并避免默认把一个设备的剪贴板广播到所有设备。

## 15. 指标与可观测性

### 15.1 会话指标

```dart
final metrics = ScrcpySessionMetricsCollector(
  sessionState: session.state,
  videoCodec: ScrcpyVideoCodec.h264.serverName,
  interval: const Duration(seconds: 1),
);

metrics.attach(video: video, audio: audioController);
metrics.updateReconnectCount(reconnectCount);
metrics.addListener(() {
  final snapshot = metrics.value;
  if (snapshot != null) print(snapshot.toJson());
});
```

当前可统计会话状态、视频/音频吞吐、解码帧率、卡顿、错误和重连次数等。指标收集器只观察，不应参与会话控制决策。

### 15.2 宿主进程指标

```dart
final processMetrics = ScrcpyProcessMetricsCollector(
  interval: const Duration(seconds: 1),
);
await processMetrics.sample();
print(processMetrics.value?.toJson());
```

Windows 当前可采集进程 CPU、工作集/内存和线程等基础数据。宿主 GPU 与端到端输入延迟仍可能为 `null`，UI 应显示“未提供”，不要显示为 0。

### 15.3 日志与隐私

可以配置 `ScrcpyLogSink` 收集分级日志。正式产品中：

- 使用 `redactedSerial` 展示或上传设备标识；
- 不记录验证码、完整剪贴板、用户文件内容；
- 错误日志应包含阶段、错误码、会话 ID，但避免包含敏感 shell 输出。

## 16. 错误处理

ADB 错误使用 `AdbException` / `AdbErrorCode`；scrcpy 错误使用 `ScrcpyException` / `ScrcpyErrorCode`。常见处理方式：

```dart
try {
  await session.start();
} on ScrcpyException catch (error) {
  switch (error.code) {
    case ScrcpyErrorCode.unsupportedCapability:
      // 例如音频不可用；若 audioRequired=false，优先允许视频继续。
      break;
    default:
      rethrow;
  }
}
```

建议 UI 分开显示：设备未授权、设备离线、server 部署失败、编码器不兼容、音频不可用、原生解码错误、控制通道关闭。不要统一显示成“连接失败”。

## 17. 正确释放资源

单会话推荐顺序：

```dart
await scrcpy.removeSession(session.id);
```

多会话推荐顺序：

1. 禁用业务侧操作入口；
2. 删除不再需要的 Group；
3. 由 `ScrcpyManager.removeSession(id)` 停止并删除单个 Session；
4. 页面整体退出时 `await scrcpy.close()`，最后 `scrcpy.dispose()`。

`dispose()` 是同步的最终兜底，不应替代异步 `stop()`/`close()`。重连、移除窗口和应用退出必须走同一套所有权规则，否则容易出现关闭后的 socket 写入、残留音频或 Texture 泄漏。

## 18. 设备墙如何由使用端组合

插件不会提供一个固定的 `DeviceWall` 公共组件。业务应用可按以下方式组合：

1. 用 `adb.watchDevices()` 维护设备目录；需要主动刷新时使用 `AdbDeviceMonitor`；
2. 每个窗口用 `ScrcpyManager` 创建一个主屏、已有屏或虚拟屏 Session；
3. 每个窗口直接放置 `ScrcpyView(session: session)`；
4. 批量控制用 `ScrcpySessionGroup` 指定成员和主控；
5. 用响应式 Grid/List 决定窗口尺寸，不让预览尺寸隐式改变 Android Display；
6. 需要广播时，由业务维护目标集合，把规范化输入复制到健康连接；
7. 批量安装/卸载走 ADB 批量任务；批量按键/触摸走 scrcpy input；
8. 用会话和进程指标决定告警、降级和重连提示。

当前 Example 已展示或正在验证的使用端功能：

- USB/网络设备列表、连接、断开、验证码配对；
- 设备详情、应用列表、文件管理和运行状态；
- 单设备投屏与控制；
- 多虚拟屏工作台；
- 指定应用在指定虚拟屏启动；
- 虚拟屏尺寸、方向、DPI 和系统装饰设置；
- 声音播放、静音、音量和单音频焦点；
- 设备墙响应式布局；
- 质量档位选择；
- ADB 批量安装、卸载等操作；
- scrcpy 按键和触摸广播；
- 会话/进程性能面板。

这些界面可作为接入示例，但产品应自行决定权限、焦点、选中状态、失败重试、窗口持久化和多租户隔离。

### 18.1 批量控制组与主控

插件提供通用的“组 + 主控”模型，使用端只负责决定选中哪些 Session：

```dart
final group = scrcpy.createGroup(
  sessions: selectedSessions,
  primary: selectedSessions.first,
);
```

组的主控决定显示哪一路画面，输入会广播到创建手势时仍健康的全部成员：

```dart
ScrcpyGroupView(group: group);
```

切换主控不会重建 Session：

```dart
group.setPrimary(anotherSession);
```

常用批量控制直接调用组：

```dart
await group.home();
await group.back();
await group.power();
await group.sendText('hello');
await group.startApplication('com.example.app');
await group.setMuted(true);
```

组内部会固定一次触摸手势的目标快照，并为每个 Session 保持独立控制通道；成员断线、重连或移出组时会被安全跳过，单个目标失败不会中断其他目标。主控切换会取消仍未结束的广播 pointer，避免残留触摸。

组不拥有 Session。删除组只停止批量控制，不关闭其中的投屏；删除 Session 时 Manager 会自动把它从所有组移除。设备墙的选择框、分组名称和持久化仍由使用端实现。

## 19. 当前平台与限制

| 能力 | Windows 主机 | 其他 Flutter 主机 |
| --- | --- | --- |
| 内置 ADB 与 server | 已实现 | 尚未交付 |
| USB/网络 ADB/配对 | 已实现 | 取决于未来 ADB backend |
| H.264 原生解码 + Texture | 已实现 | 尚未交付 |
| H.265 / AV1 原生显示 | 协议可选，当前未作为可用播放链路承诺 | 尚未交付 |
| Opus 音频播放 | 已实现 | 尚未交付 |
| 鼠标、键盘、触摸 | 已实现 | 尚未交付 |
| 虚拟屏、多应用窗口 | 已实现并持续兼容性验证 | 尚未交付 |
| 设备墙 UI | Example/使用端 | 使用端自行实现 |
| Web | 不适用 | 暂无可交付方案 |
| 鸿蒙主机控制 Android | 暂无 | 规划方向，未实现 |

仍需集中验证或继续开发的项目：

- Android 11 开发板的音频确认弹窗、`output` 捕获和真实播放；
- USB 掉线、设备重启、多个虚拟屏并存后的重连稳定性；
- 触摸广播在主屏/虚拟屏、旋转、缩放和边缘手势下的真实设备验证；
- 长时间多会话播放的内存、句柄、CPU/GPU 和音画连续性；
- H.265/AV1 的平台解码实现；
- 无重连的运行时质量动态调整；
- Android/iOS/macOS/Linux/Web/鸿蒙宿主实现。

## 20. 分包时可观察的天然边界

以下不是强制方案，而是根据当前职责形成的检查表：

| 候选边界 | 可包含内容 | 应避免包含 |
| --- | --- | --- |
| `adb_client` | 接口、模型、解析、取消、设备/应用/文件/状态/批量逻辑 | Process、Flutter、scrcpy |
| `adb_client_process` | 桌面 ADB 进程、命令执行、forward/sync/package 实现 | UI、会话编排 |
| ADB resources/backend | 内置 ADB 定位、版本、校验、各平台分发 | scrcpy server |
| scrcpy protocol/core | server 参数、视频/音频拆包、控制消息、会话状态机 | Flutter Widget、Windows 解码器 |
| `scrcpy_flutter` | Flutter 控制器、InputLayer、VideoView、剪贴板适配、高层会话入口 | 设备墙产品页面 |
| `scrcpy_flutter_windows` | Media Foundation、Texture、Opus/音频输出、Windows 进程指标 | Android 业务逻辑 |
| example/product | 设备墙、工作台、音频焦点选择、广播目标、批量操作页面 | 被下层库反向依赖 |

分包前尤其需要处理四个交叉点：

1. **应用名称增强**：包列表属于 ADB，但本地化 label 当前借助 scrcpy server；
2. **资源分发**：ADB 二进制和 scrcpy server 应分别归属清楚，同时保留统一默认初始化体验；
3. **平台指标**：会话指标可留在 core，Windows 进程/GPU 指标应进入平台实现；
4. **音频焦点**：通用协调器可留作可复用工具，但“点击哪个设备发声”必须由产品层决定。

## 21. 最小嵌入流程清单

- [ ] 初始化默认 client，并确认打包资源可找到；
- [ ] 发现设备，只允许 `isReady` 设备进入会话；
- [ ] 创建并持有 Session/Manager；
- [ ] 启动 Connection；
- [ ] 创建视频控制器并渲染 `ScrcpyVideoView`；
- [ ] 在相同 fit/alignment 上覆盖 `ScrcpyInputLayer`；
- [ ] 可选创建音频控制器并建立业务音频焦点策略；
- [ ] 可选启用剪贴板和指标；
- [ ] 监听状态与 `reconnectedConnections`，完整替换旧控制器；
- [ ] 页面关闭时按所有权顺序释放全部资源；
- [ ] 多窗口、批量和设备墙逻辑保留在宿主应用。

更偏 API 签名的简版索引见 [public-api.md](public-api.md)，内部依赖和视频数据流见 [architecture.md](architecture.md)，生命周期细节见 [lifecycle.md](lifecycle.md)，开发与验证进度见 [development-plan.md](development-plan.md)。
