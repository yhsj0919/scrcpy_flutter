# 多实例与资源生命周期

更新于 2026-09-01。本约束适用于插件被其他 Flutter 应用嵌入以及后期设备墙场景。

## 所有权

```text
宿主应用
└── ScrcpyClient（可创建多个，不依赖全局可变单例）
    ├── AdbClient/transport（由 Client 注入并持有）
    ├── ScrcpySession A
    │   ├── cancellation scope
    │   ├── server process / video+control socket / forward / remote server
    │   ├── video controller / decoder / texture
    │   └── input controller
    └── ScrcpySession B（资源与 A 完全独立）
```

- 宿主负责保留并最终释放 `ScrcpyClient` 及它创建的 Session。
- 每个 Session 独立拥有 SCID、端口、远端 server 路径、进程和 socket；Controller 独立拥有解码器和 texture，不允许使用“当前唯一会话”全局槽位。
- 视频 Widget 只观察 Controller，不拥有 Session、Player 或 texture；Widget 从树中移除不等同于结束 Session。
- 批量任务拥有自己的取消令牌和逐设备子任务，不取得 Session 的资源所有权。

## 状态与并发规则

- `prepare()` 并发调用合并为同一个 Future，避免重复设备查询和后续重复部署 server。
- `dispose()` 必须幂等；调用后不能重新启动或准备会话。
- dispose 与异步 prepare/start 竞争时，以 disposed 为最终状态，异步完成不得把状态恢复为 ready/streaming。
- stop/dispose 的清理顺序为：停止接受输入 → 取消 Dart 订阅 → 释放原生 texture/解码器 → 关闭控制/视频 socket → 停止 server → 删除本 Session 的 forward 和远端文件。
- 任一步清理失败都要继续清理其余资源，并聚合诊断信息；不得清理其他 Session 的资源。

## 宿主生命周期

- 页面切换：是否保持 Session 由宿主决定；仅销毁视频 Widget 不自动断开。
- 窗口关闭、应用退出：宿主应 dispose 所有 Session；平台插件应设置最终兜底清理。
- 设备拔出或网络断开：Session 进入 error/disconnected，清理本地资源；自动重连策略后续由可取消的 Session 策略控制。
- Flutter hot restart：开发环境可能跳过正常 Dart dispose，平台侧必须能够识别并回收上一次注册器生命周期内创建的资源。

## 资源表

| 资源 | 所有者 | 唯一标识 | 正常停止 | 启动失败/断线 |
| --- | --- | --- | --- | --- |
| ADB forward | VideoConnection | 本地动态 TCP 端口 | 按精确端口移除 | connector/connection 清理 |
| 远端 server 文件 | VideoConnection | 含随机 SCID 的路径 | `rm -f` 精确路径 | connector/connection 清理 |
| server 进程 | VideoConnection | 本 Session 的运行句柄 | 只终止持有句柄 | connector/connection 清理 |
| 视频/控制 socket | VideoConnection | 本 Session 的端口和连接 | 幂等关闭 | 部分建立也逐个关闭 |
| 原生解码器/Texture | VideoController | texture ID | MethodChannel dispose | 即使 dispose 失败也继续关闭连接 |

当前实现的 `close/stop/dispose` 均幂等。任一清理步骤失败不会阻断后续步骤；Session 在启动未完成时被停止或销毁，也会回收迟到的连接。

