# P4 断线与重连验收报告

验收日期：2026-09-02

## 策略

- `ScrcpyReconnectPolicy` 配置最大次数、初始间隔、最大间隔和指数倍率
- 默认 `maxAttempts=0`，嵌入宿主必须显式启用，不改变既有生命周期行为
- 意外 transport done 进入 `disconnected` / `reconnecting`
- 用户 `stop()` 和 `dispose()` 设置停止意图并立即取消退避等待
- 同一时间只允许一个 `_starting` 和一个 `_reconnecting` 任务
- 每次失败重新检查设备和创建完整的新 server/socket/forward
- 成功连接通过 `reconnectedConnections` 输出
- 重试耗尽进入 `error` 并输出一次终止错误

## Demo

- 最多重试 5 次
- 退避为 1、2、4、8、8 秒
- 重连成功后停止并释放旧 Texture
- 使用新连接重建视频、输入和剪贴板控制器
- 用户点击停止画面不会触发重连

## 自动测试

- [x] 意外断线创建一个替代连接
- [x] 重连成功恢复 `streaming`
- [x] 用户停止取消待执行重连
- [x] 停止后不产生重复连接
- [x] 指数退避与最大间隔
- [x] 非法策略参数
- [x] 重试耗尽次数准确且输出终止错误

## 真机异常注入

- 设备：Xiaomi 23127PN0CC，Android 16，USB ADB
- 初始 SCID：`7caa8113`
- 注入方式：使用 `ps` 定位包含本次 SCID 的实际 `app_process` PID，只终止该 server 子进程
- server 输出：`Terminated`
- 自动恢复 SCID：`59454a74`
- 新连接解码帧：2
- 总耗时：约 3 秒（不含构建）
- ADB 连接未中断，旧连接完成清理

## 结论

P4-02 验收通过。
