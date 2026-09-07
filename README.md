# scrcpy_flutter

Windows 构建默认随插件分发固定版本的 ADB 及其运行库，宿主不需要预装 Android SDK 或配置 PATH；开发者仍可通过公开构造参数覆盖 ADB 路径。

一个基于 scrcpy server 的可嵌入式 Flutter Android 设备显示与控制插件。它首先是供其他 Flutter 应用依赖的插件包，仓库中的 example 只用于演示和验收。长期目标是实现由 Flutter 渲染和管理的低延迟多设备墙。

项目目前已完成 Windows 单设备管理、视频与控制闭环、同设备多虚拟屏工作台、libopus Windows 音频播放，以及跨设备设备墙的基础组合示例；多设备兼容性和长时间稳定性仍在持续验证。

项目目前为内部开发版本（`publish_to: none`），尚未选定项目级开源许可证。第三方组件各自的许可证与来源见[第三方组件清单](docs/third-party-components.md)。

## 开箱即用

```dart
final scrcpy = createDefaultScrcpyManager();
final adb = scrcpy.adb;

final session = await scrcpy.createSession(
  deviceSerial: device.serial,
  audioEnabled: true,
);

ScrcpyView(session: session);
```

创建默认竖屏虚拟屏并打开应用：

```dart
final session = await scrcpy.createSession(
  deviceSerial: device.serial,
  display: ScrcpyDisplay.virtual(
    width: 720,
    height: 1280,
    dpi: 240,
    application: 'com.example.app',
  ),
);
```

`ScrcpyView` 可以放在任意 Flutter 布局中；View 销毁不会关闭 Session，Session 统一由 `ScrcpyManager` 管理。

批量控制只需要建立一个组并指定主控画面：

```dart
final group = scrcpy.createGroup(
  sessions: selectedSessions,
  primary: selectedSessions.first,
);

ScrcpyGroupView(group: group);
await group.home();
```

## 项目文档

- [完整使用指南与功能清单](docs/usage-guide.md)
- [架构与视频管线](docs/architecture.md)
- [公开 API 基线](docs/public-api.md)
- [生命周期与资源所有权](docs/lifecycle.md)
- [实现进度与功能进度](docs/status.md)
- [可执行开发计划与交接清单](docs/development-plan.md)
- [功能范围与优先级](docs/features.md)

## 第一个里程碑

第一阶段以 Windows 主机和单台 Android 设备为目标：

1. 通过 ADB 发现设备。
2. 部署并启动版本匹配的 `scrcpy-server`。
3. 建立视频连接和控制连接。
4. 保留 scrcpy codec、session 和 frame metadata，拆分 H.264 编码包。
5. 通过平台原生解码器输出 Flutter Texture。
6. 覆盖输入层，映射坐标并发送触摸事件。

