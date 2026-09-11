# 公开 API 基线

更新于 2026-09-07。普通接入方只需要：

```dart
import 'package:adb_client/adb_client.dart';
import 'package:scrcpy_flutter/scrcpy_flutter.dart';
```

`adb_client` 负责设备发现、连接、配对、Shell、文件和应用管理；`scrcpy_flutter` 负责会话、音视频与控制。不要导入 `src/`。只有自定义传输、解码器或诊断工具才使用 `scrcpy_advanced.dart`。

## 初始化与设备监听

```dart
final scrcpy = createDefaultScrcpyManager();
final adb = scrcpy.adb;

final devices = await adb.discoverDevices();
final subscription = adb.watchDevices().listen((snapshot) {
  // 使用 snapshot.devices 更新界面。
});

final mdnsSubscription = adb.watchMdnsServices().listen((snapshot) {
  // 使用 snapshot.services 展示可配对、可连接的无线调试设备。
});
```

两种监听都在建立订阅时启动、取消订阅时释放内部轮询。`watchDevices()` 会把 mDNS connect 服务合并为可连接网络设备；只有配对页面需要单独监听 `watchMdnsServices()`。不支持 mDNS 的平台返回空快照，不要求业务层判断平台。

Wireless Debugging 建议直接调用 `adb.pairAndConnect(pairingEndpoint, pairingCode)`。它会在配对后自动发现动态连接端口；仅当需要自定义配对 UI 的实时列表时，才需要直接使用 `watchMdnsServices()`。

Windows 默认使用插件内置的 ADB 和 scrcpy server，宿主无需安装 Android SDK。必要时可向 `createDefaultScrcpyManager()` 传入 `adbExecutablePath` 或 `scrcpyServerPath`。

## 创建和展示会话

```dart
final session = await scrcpy.createSession(
  deviceSerial: device.serial,
  audioEnabled: true,
  audio: const ScrcpyAudioOptions(
    initiallyMuted: false,
    initialVolume: 1,
  ),
  video: const ScrcpyVideoOptions(
    maxSize: 1920,
    maxFps: 60,
    bitRate: 8000000,
  ),
);

ScrcpyView(
  session: session,
  blockHostGestures: true,
);
```

`ScrcpyView` 可放入任意 Flutter 布局，也可以循环 `scrcpy.sessions` 构建多个画面。移除 View 不关闭 Session；显式关闭使用：

默认情况下，投屏区域会消费远程触摸、拖动和滚轮手势，避免同时驱动外层页面。需要宿主手势穿透时设置 `blockHostGestures: false`。

```dart
await scrcpy.removeSession(session.id);
```

## 截图

截图直接复制 Session 原生解码器的最后一帧，不调用 ADB、不暂停视频，也不触发重连：

```dart
final screenshot = await session.captureFrame();
await screenshot.saveToFile(r'D:\captures\device.png');
```

`ScrcpyScreenshot` 同时提供 `width`、`height` 和 PNG 格式的 `pngBytes`，宿主可以自行上传、预览或写入其他存储。尚未解出首帧、Session 已停止以及文件写入失败均抛出 `ScrcpyException`，错误码为 `ScrcpyErrorCode.captureFailure`。

## 屏幕录制

```dart
await session.startRecording(r'D:\captures\device.mp4');
// ...
final frames = await session.stopRecording();
```

Windows 后端将 scrcpy 的 H.264 编码包按原始 PTS 直接封装为 MP4，不重新编码。当前版本先提供视频录制，不包含音频；开始录制后会等待下一个关键帧，停止、旋转重建或关闭 Session 时会完成 MP4 封装。

## 虚拟屏

默认虚拟屏为竖屏 720×1280：

```dart
final appSession = await scrcpy.createVirtualSession(
  deviceSerial: device.serial,
  application: 'com.example.app',
  audioEnabled: true,
);
```

完整配置：

```dart
final appSession = await scrcpy.createSession(
  deviceSerial: device.serial,
  display: ScrcpyDisplay.virtual(
    width: 1080,
    height: 1920,
    dpi: 420,
    systemDecorations: true,
    application: 'com.example.app',
  ),
);
```

宽高是 Android Display 像素，不是 Flutter 预览框尺寸。View 只按布局缩放画面，不会隐式修改虚拟屏。已有 Display 使用 `ScrcpyDisplay.existing(displayId)`。

## 控制

```dart
await session.home();
await session.back();
await session.power();
await session.sendText('hello');
await session.setMuted(true);
await session.setVolume(0.5);
await session.startApplication('com.example.app');
await session.resizeDisplay(width: 1080, height: 1920);
```

View 默认处理鼠标、触摸和键盘：左键触摸，中键 Home，右键 `BACK_OR_SCREEN_ON`。坐标转换、旋转、黑边和边缘坐标由内部处理。

## 批量控制

公共抽象只有“组、成员、主控”：

```dart
final group = scrcpy.createGroup(
  sessions: selectedSessions,
  primary: selectedSessions.first,
);

ScrcpyGroupView(group: group);
group.setPrimary(otherSession);
await group.home();
```

主控 View 上的输入会广播给组内当前可用的 Session。指针生命周期、断线过滤和单目标失败隔离由插件处理；设备选择和网格布局仍属于使用端。

## 状态与释放

```dart
session.state.addListener(() => print(session.state.value));

await subscription.cancel();
await scrcpy.close();
scrcpy.dispose();
```

状态包括 `idle`、`preparing`、`starting`、`streaming`、`disconnected`、`reconnecting`、`error` 和 `disposed`。错误使用 `ScrcpyException` 与 `ScrcpyErrorCode`。

## API 分层

- 默认入口：Manager、Session、View、控制组与常用配置。
- ADB 包：连接、配对、设备、应用、文件、状态与批量 ADB 操作。
- 高级入口：原始连接、协议、平台 Controller、指标与自定义后端。
- Example：工作台和设备墙等产品形态，不作为插件公共 Widget。
