# P2 会话生命周期验收报告

## 结论

- [x] 同一台设备连续启动、获取真实解码帧并停止 50 次。
- [x] 每轮停止后原生 Texture ID 已失效。
- [x] 测试结束后无 `localabstract:scrcpy_*` ADB forward。
- [x] 测试结束后无 `com.genymobile.scrcpy.Server` 进程。
- [x] 测试结束后无 `/data/local/tmp/scrcpy-server-*.jar` 临时文件。

P2-05 验收通过。

## 验收环境

- 日期：2026-09-01
- 宿主：Windows Debug
- 设备：Rockchip ZC-3588A，Android 15
- scrcpy server：4.1（插件内置）
- 视频参数：H.264、最大 320 px、15 FPS、1 Mbps
- 控制通道：启用

设备序列号只通过 `--dart-define=SCRCPY_DEVICE_SERIAL=...` 注入测试，不写入仓库和本报告。

## 自动化入口

真机集成测试位于 `example/integration_test/native_video_test.dart`。轮数由 `SCRCPY_STRESS_ITERATIONS` 控制，允许 1 到 50；每轮执行以下可判断步骤：

1. 创建独立 Session，并验证状态进入 `streaming`。
2. 创建原生视频 Texture，等待 `frameCount > 0`。
3. 停止 Session 和视频控制器，并验证状态回到 `ready`。
4. 再次查询已释放的 Texture ID，必须返回 `PlatformException`。
5. dispose 本轮 Controller 和 Session 后进入下一轮。

示例命令：

```powershell
flutter test integration_test/native_video_test.dart -d windows `
  --dart-define=SCRCPY_DEVICE_SERIAL=<设备序列号> `
  --dart-define=SCRCPY_STRESS_ITERATIONS=50
```

## 结果与异常记录

- 50 轮最终验收耗时约 57 秒，`max_iteration=50`，测试结果为 `All tests passed`。
- 每轮均取得至少 1 个真实解码帧，第 50 轮取得 2 帧。
- 一次在此前测试被中断、环境未重新确认时的运行于第 10 轮后失败；随后 15 轮诊断运行全部通过，最终独立 50 轮验收全部通过。该记录保留用于后续稳定性回归，不将单次成功替代 P1-05 的 30 分钟连续播放验收。
- 最终验收完成后的外部资源计数：ADB forward `0`、server 进程 `0`、远端临时 jar `0`。

## 相关测试

- `test/scrcpy_flutter_test.dart`：使用可计数假连接验证 50 次启停，每个连接恰好关闭一次。
- `test/native_scrcpy_video_test.dart`：验证 Texture 清理失败时仍继续关闭 Connection。
- `example/integration_test/native_video_test.dart`：Windows + Android 真机完整链路验收。
