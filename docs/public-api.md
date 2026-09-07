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
```

Windows 默认使用插件内置的 ADB 和 scrcpy server，宿主无需安装 Android SDK。必要时可向 `createDefaultScrcpyManager()` 传入 `adbExecutablePath` 或 `scrcpyServerPath`。

## 创建和展示会话

```dart
final session = await scrcpy.createSession(
  deviceSerial: device.serial,
  audioEnabled: true,
  video: const ScrcpyVideoOptions(
    maxSize: 1920,
    maxFps: 60,
    bitRate: 8000000,
  ),
);

ScrcpyView(session: session);
```

`ScrcpyView` 可放入任意 Flutter 布局，也可以循环 `scrcpy.sessions` 构建多个画面。移除 View 不关闭 Session；显式关闭使用：

```dart
await scrcpy.removeSession(session.id);
```

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
