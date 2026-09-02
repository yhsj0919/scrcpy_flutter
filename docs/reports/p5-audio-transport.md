# P5-07 scrcpy 音频协议与传输

更新于 2026-09-02。

## 已实现

- `ScrcpySessionConfiguration` 支持可选音频、`audioRequired`、codec 和码率。
- Session 按 video、audio、control 顺序建立并独立持有三个 socket。
- 解析 scrcpy 4.1 音频 codec metadata、不可用标记、12 字节帧头、config 包、PTS 和 payload。
- 首版默认 Opus，同时识别 AAC、FLAC 和 raw PCM codec ID。
- 音频可选时，不可用或音频流结束不影响视频；要求音频时，禁用、协议错误或就绪超时会终止并清理 Session。
- 原有 `audioEnabled: false` 为默认值，纯视频调用不增加 socket。

## 自动化验证

- `test/scrcpy_audio_packet_test.dart` 覆盖任意分片、四种 codec、禁用标记、config/普通包、非法 codec、非法包长和配置校验。
- 音频、视频、Session 和 Native Texture 定向回归共 26 项通过。
- `dart analyze lib test` 通过，无问题。
- 根目录完整 analyzer 会递归分析两个子 package，但当前根解析上下文没有子 package 的 `package:test`，产生 236 个既有依赖解析错误；本次改动涉及的 `lib` 和 `test` 定向分析无问题。

## 真机记录

- 设备：Xiaomi 23127PN0CC，Android 16，Windows Debug 宿主。
- 命令：`flutter test integration_test/audio_transport_test.dart -d windows --dart-define=SCRCPY_DEVICE_SERIAL=<serial>`。
- 结果：通过；取得 Opus codec metadata，约 1 秒内取得 11 个包，49 字节 payload、185 字节 transport data。
- PTS 保留 server 原值。该设备编码器启动时首批输出存在约 18 ms 的短暂回跳，随后递增，因此传输层不重排、不改写时间戳；播放层需按自身缓冲策略处理。
- 测试结束后 Session 正常停止并执行 socket、server、forward 和远端资源清理。

## 待补验收

P5-07 暂不勾选。仍需在 Android 10、11 和 12+ 各补充音频不可用/受限行为，尤其验证 Android 11 启动条件和禁止 playback capture 应用的提示及可选降级。完成这些兼容性记录后再进入 P5-08 Windows 播放。
