# 多实例与资源生命周期

更新于 2026-08-31。本约束适用于插件被其他 Flutter 应用嵌入以及后期设备墙场景。

## 所有权

```text
宿主应用
└── ScrcpyClient（可创建多个，不依赖全局可变单例）
    ├── AdbClient/transport（由 Client 注入并持有）
    ├── ScrcpySession A
    │   ├── cancellation scope
    │   ├── server process / socket / forward / remote server
    │   ├── video controller / player / texture
    │   └── input controller
    └── ScrcpySession B（资源与 A 完全独立）
```

- 宿主负责保留并最终释放 `ScrcpyClient` 及它创建的 Session。
- 每个 Session 必须独立拥有 SCID、端口、远端 server 路径、进程、socket、Player 和 texture，不允许使用“当前唯一会话”全局槽位。
- 视频 Widget 只观察 Controller，不拥有 Session、Player 或 texture；Widget 从树中移除不等同于结束 Session。
- 批量任务拥有自己的取消令牌和逐设备子任务，不取得 Session 的资源所有权。

## 状态与并发规则

- `prepare()` 并发调用合并为同一个 Future，避免重复设备查询和后续重复部署 server。
- `dispose()` 必须幂等；调用后不能重新启动或准备会话。
- dispose 与异步 prepare/start 竞争时，以 disposed 为最终状态，异步完成不得把状态恢复为 ready/streaming。
- stop/dispose 的清理顺序为：停止接受输入 → 取消读写 → 关闭控制/视频 socket → 停止 server → 删除本 Session 的 forward 和远端文件 → 释放 Player/texture。
- 任一步清理失败都要继续清理其余资源，并聚合诊断信息；不得清理其他 Session 的资源。

## 宿主生命周期

- 页面切换：是否保持 Session 由宿主决定；仅销毁视频 Widget 不自动断开。
- 窗口关闭、应用退出：宿主应 dispose 所有 Session；平台插件应设置最终兜底清理。
- 设备拔出或网络断开：Session 进入 error/disconnected，清理本地资源；自动重连策略后续由可取消的 Session 策略控制。
- Flutter hot restart：开发环境可能跳过正常 Dart dispose，平台侧必须能够识别并回收上一次注册器生命周期内创建的资源。

## 当前实现范围

P0 的 Session 已实现设备准备、并发 prepare 合并、错误状态和幂等 dispose。server、socket、forward、Player 和 texture 将在 P1/P2 接入，但必须遵守上述所有权和清理顺序。
