# 多实例与资源生命周期

更新于 2026-09-07。

```text
宿主应用
└── ScrcpyManager
    ├── ADB 工具箱
    ├── ScrcpySession（主屏或虚拟屏）
    │   ├── server / socket
    │   ├──视频解码器 / Flutter Texture
    │   ├──音频播放器
    │   └──输入通道
    └── ScrcpySessionGroup（只引用 Session）
```

- Manager 拥有它创建的 Session，并负责统一关闭。
- Session 拥有连接、解码、Texture、音频和输入生命周期。
- View 只展示和操作 Session；View 移除时不关闭 Session。
- Group 只描述成员和主控，不改变 Session 所有权。
- 设备墙、窗口布局和选择状态属于宿主应用。

## 推荐用法

```dart
final scrcpy = createDefaultScrcpyManager();
final session = await scrcpy.createSession(deviceSerial: serial);

// Widget 中：ScrcpyView(session: session)

await scrcpy.removeSession(session.id);

// 应用退出：
await scrcpy.close();
scrcpy.dispose();
```

优先调用异步 `close()` 完成有序清理，`dispose()` 是同步兜底；两者都应幂等。

## 断线与重连

Session 按 `ScrcpyReconnectPolicy` 重建完整媒体链路。新的 socket、输入通道、解码器和音频播放器由 Session 内部替换，View 不需要重建。

批量控制在按下时固定目标集合，在抬起或取消时结束该批指针，避免重连或切换主控产生悬挂触点。

## 内部清理顺序

1. 停止接受输入并取消重连；
2. 停止并释放音频；
3. 停止并释放视频解码器与 Texture；
4. 关闭控制、音频和视频 socket；
5. 停止本 Session 的 server；
6. 删除精确匹配的 ADB forward 与远端临时文件。

单步失败不能阻断后续回收，也不能影响其他 Session。
