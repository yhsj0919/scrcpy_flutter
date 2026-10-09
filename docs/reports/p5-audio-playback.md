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

已增加公开的 `ScrcpyAudioFocusManager`，并在工作台接入显式单音频焦点：创建窗口时可选择是否启用设备音频，点击对应预览可切换焦点，非焦点窗口保持静音；窗口关闭、音频断流或播放错误时会自动注销并释放焦点。音频故障不会替换或中断视频画面。

工作台已启用最多 5 次 Session 自动重连。收到替换连接后会串行注销旧音频焦点、停止并销毁旧视频/音频控制器、替换输入控制器，再启动新视频和可选音频；界面显示累计重连次数。这样避免旧 socket、旧 texture 或失效音频焦点残留。

新建虚拟屏默认启用电脑音频。Xiaomi 14 真机验证中，虚拟屏使用 `output` 时系统将 RemoteSubmix 与 A2DP 建成复制路由，手机端仍然发声，因此工作台改用与主界面一致的 scrcpy `playback` 音源并关闭 `audio_dup`。创建界面和屏幕卡片会分别显示开关语义及当前音频状态；已经存在的虚拟屏需要关闭后重新创建，启动参数才会生效。

Rockchip ZC-3568K Android 11 已确认处于解锁状态、存在 `c2.android.opus.encoder`，但设备仍明确禁用了 `playback` 音频流。这属于部分 Android 11 厂商 ROM 的 shell 前台判定兼容问题。曾用于抢占 shell 前台的 `HeapDumpActivity` 绕行会打开系统堆转储页面，现已移除。主画面和设备墙使用自动音源：Android 11 选择 `output`，Android 12 及以上保持已验证的 `playback`；虚拟屏工作台固定使用 `playback`。不支持时保持视频运行并报告音频不可用。

待测记录（2026-09-03）：用户稍后使用 Android 11 开发板复验。通过判定为不出现堆转储弹窗、收到 Opus 数据、状态进入“电脑播放中”、电脑实际有声且 `output` 模式下开发板停止本地发声；失败时保留 scrcpy server 完整日志并正常降级为仅视频。

P5-08 暂不勾选，等待用户执行一次基本断连/恢复验证。切换爆音和 30 分钟播放验收按 2026-09-03 决策统一延期，由用户后续集中执行。Android 10/12+ 兼容性也暂时跳过，不阻塞后续功能开发。
