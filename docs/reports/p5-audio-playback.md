# P5-08 Windows 音频播放

更新于 2026-09-03。

## 实现

- 官方 libopus 1.5.2 静态编入 Windows 插件，避免依赖可选的 Windows Media Foundation Opus 组件。
- 原生层将 scrcpy Opus payload 解码为 48 kHz、双声道、16-bit PCM，通过 WinMM `waveOut` 输出。
- PCM 队列最多保留 24 个缓冲；积压时丢弃新缓冲并计数，停止时 reset、回收 header 并关闭输出设备。
- `ScrcpyAudioController` 支持启动、停止、静音、0～1 音量及状态监听。
- 单设备 Demo Session 默认请求 Opus 并随画面启动播放器，页面提供静音按钮、音量滑块和实时解码/播放/丢弃统计；音频不可用时只提示错误，画面继续运行。
- 多虚拟屏工作台在焦点管理完成前不自动开启音频，避免多个窗口同时播放。
- 状态公开 transport bytes、packet、decoded packet、played/dropped buffer 和 buffered bytes。
- 音频 Controller 只拥有原生播放器和 audio stream 订阅；停止音频不会关闭共享的视频/控制连接。

## 真机结果

- 宿主：Windows Debug。
- 设备：Xiaomi 23127PN0CC，Android 16。
- 测试：`example/integration_test/audio_playback_test.dart`。
- 结果：通过；样本中收到 55 个 packet、解码 54 个、完成播放 48 个 PCM buffer、丢弃 0、在途 PCM 23040 bytes。
- 0.5 音量、静音、取消静音和最终资源清理通过。
- 根插件 78 项测试通过，`dart analyze lib test` 无问题；Windows Debug 与 Release 构建均通过，libopus 静态进入插件，无额外运行时 DLL。
- Demo 定向 analyzer、2 项 Widget 测试和接入后的 Windows Debug 构建通过。

## 未完成

P5-08 暂不勾选。仍需实现多个窗口之间的显式音频焦点管理、切换爆音检查、断线重连和 30 分钟播放验收。Android 10/11/12+ 兼容性按 2026-09-03 用户决策暂时跳过，不阻塞 Windows 播放开发。
