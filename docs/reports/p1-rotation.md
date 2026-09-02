# P1 视频旋转与动态分辨率验收报告

## 结论

- [x] 真机横竖屏连续切换 20 次。
- [x] 每次切换后视频宽高正确交换。
- [x] 每次原生 Texture 重建后均取得真实解码帧。
- [x] 无永久黑屏、崩溃或不可恢复错误。
- [x] 测试结束后恢复设备原始旋转设置。
- [x] 测试结束后无 scrcpy ADB forward 和 server 进程残留。

P1-04 验收通过。

## 验收环境

- 日期：2026-09-02
- 宿主：Windows Debug
- 设备：Xiaomi 23127PN0CC，Android 16
- scrcpy server：4.1（插件内置）
- 视频参数：H.264、最大 640 px、30 FPS、2 Mbps

设备序列号未写入报告。

## 自动化过程

测试入口：`example/integration_test/rotation_video_test.dart`。

1. 读取并保存 `accelerometer_rotation` 和 `user_rotation`。
2. 使用 `wm user-rotation lock` 在 0/1 方向间交替切换 20 次。
3. 每次等待视频尺寸从上一方向交换。
4. 查询当前原生 Texture 的 `frameCount`，必须大于 0。
5. `finally` 恢复原旋转模式和 Settings 值，并停止 Session。

第一次在固定方向的 Rockchip 设备上运行时，系统忽略旋转命令，测试按预期在首轮超时并恢复设置；该结果不是视频后端失败。更换支持旋转的 Xiaomi 设备后完成正式验收。

## 结果

- 20/20 次通过，总耗时约 12 秒。
- 竖屏解码尺寸：286×640。
- 横屏解码尺寸：640×286。
- 每次重建后的首批查询取得 3–8 个显示帧。
- 结束后旋转设置恢复为原值。
- 结束后 scrcpy forward `0`、server 进程 `0`。

