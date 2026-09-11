# 跨平台适配基线

更新于 2026-09-10。

各平台当前实现状态和逐项勾选结果见 `docs/platform-feature-matrix.md`。本文保留实现要求与验收基线；功能完成度只在该矩阵维护，避免多份文档出现不同口径。

本文是新增宿主平台的实施与验收清单。平台后端必须复用公共 ADB、scrcpy 协议、Session 和 Flutter Widget；业务页面不得按平台复制一套逻辑。某项受系统限制时，后端返回明确的能力状态或空结果，并在平台差异表中记录原因。

本文中的复选框是平台报告模板，不表示所有平台的全局完成状态。开始一个平台时，在 `docs/reports/` 建立对应报告，引用并逐项勾选本清单；完成证据写入该报告。平台汇总状态以本文末尾的差异表和开发计划为准。

## 固定边界

```text
Flutter 公开 API 与 Widget
  -> Session、协议、控制、坐标和诊断（共享 Dart）
     -> AdbClient（平台 transport）
     -> ScrcpyVideoBackend（平台解码与 Texture）
     -> ScrcpyAudioBackend（平台解码与播放）
     -> PlatformLifecycle / CredentialStore（平台服务）
```

- `adb_client` 管设备发现、连接、配对、shell、sync、forward、应用、文件、状态和批量任务。
- `scrcpy_flutter` 依赖 `AdbClient`，管理 server、Session、音视频、控制和显示源。
- `ScrcpyView(session: session)` 在各平台保持相同用法。
- example 只组合公开 API，不承载平台实现。
- Web 等不支持某项能力的平台提供空实现或 `unsupportedCapability`，使用端不写平台判断。

## A. ADB 后端清单

- [ ] 枚举 USB、已连接网络设备及授权状态。
- [ ] 经典 TCP ADB 连接和断开。
- [ ] ADB RSA 首次授权、持久化和密钥轮换。
- [ ] Wireless Debugging TLS 验证码配对。
- [ ] mDNS/NSD 发现 `_adb-tls-pairing._tcp` 与 `_adb-tls-connect._tcp`。
- [ ] `discoverMdnsServices()` 一次性发现。
- [ ] `watchMdnsServices()` 自动更新、去重、取消和空实现。
- [ ] `shell` 正确处理参数、环境变量、UTF-8 和退出状态。
- [ ] 长运行 shell 支持 stdout、stderr、退出和主动终止。
- [ ] sync push/pull 支持大文件、取消和失败清理。
- [ ] `localabstract` 动态 forward，端口和 socket 在 Session 结束后释放。
- [ ] USB 热插拔、网络切换、设备重启和应用恢复后状态正确。
- [ ] 凭据进入系统安全存储，日志不输出私钥、验证码和完整设备标识。

验收至少覆盖：拒绝授权、错误验证码、错误端口、设备离线、传输中断、重复连接和并发 Session。

## B. scrcpy server 与协议清单

- [ ] scrcpy-server 与插件一起分发，不依赖宿主预装 scrcpy。
- [ ] 首次运行释放到应用私有目录并校验 SHA-256。
- [ ] server、启动参数和控制协议使用同一版本。
- [ ] 启动失败能取得 server 日志，错误不会表现为无限等待。
- [ ] 主屏、已有 display ID 和 `new_display` 使用同一 Session 模型。
- [ ] 解析 codec、设备、frame metadata、配置帧、关键帧和 PTS。
- [ ] 视频、音频和控制 socket 建立顺序兼容当前 scrcpy 版本。
- [ ] 断线、停止、重连和异常退出均清理 server、forward、socket 与临时文件。
- [ ] 升级上游前运行协议 fixture、真机视频、控制和资源回收回归。
- [ ] Android/Flutter 构建插件使用当前 AGP 推荐的 Built-in Kotlin，不依赖将被移除的 KGP 兼容开关。

## C. 视频后端清单

- [ ] 至少支持 H.264；H.265、AV1 按平台能力声明。
- [ ] 使用平台硬件解码器并输出 Flutter Texture，编码视频不逐帧经 MethodChannel 搬运。
- [ ] 首个配置帧和首个关键帧能启动解码，首屏等待有超时和诊断。
- [ ] 只显示最新可用帧；队列积压时丢旧帧，避免延迟持续增大。
- [ ] 正确处理 stride、slice height、crop rect、像素格式和颜色矩阵，避免花屏、绿线和偏色。
- [ ] 动态分辨率、设备旋转和虚拟屏尺寸变化时安全重建解码器与 Texture。
- [ ] Texture 创建、注册、尺寸变更、失效和释放遵守 Flutter 当前平台 API。
- [ ] 页面移除、应用后台、窗口最小化及设备断开后不再提交无效 Surface。
- [ ] 截图读取稳定帧，不暂停视频；不支持时返回能力错误。
- [ ] 录屏保留时间戳并可靠 finalize；失败时不留下占用中的文件。

统一记录首帧时间、显示 FPS、解码输入 FPS、丢帧、视频码率、队列深度、CPU、GPU 和内存。

## D. 音频后端清单

- [ ] 根据 Android SDK 和 scrcpy 返回值判断音频捕获能力。
- [ ] 支持 Opus；其他 codec 按平台能力声明。
- [ ] 解码和播放不阻塞视频、控制或 Flutter UI 线程。
- [ ] 音频时间戳、缓冲长度和欠载策略不会逐步累积延迟。
- [ ] Session 静音、音量和停止播放立即生效。
- [ ] 同设备主屏与虚拟屏的音频来源限制有明确提示。
- [ ] 多 Session 使用统一音频焦点，同一时刻只有选定窗口输出。
- [ ] 切换焦点时旧输出先静音，新输出再启用；注册、注销和重连保持一致。
- [ ] 音频不支持或启动失败时视频继续运行。
- [ ] 耳机、蓝牙、系统输出设备变化及应用前后台切换后恢复正确。

Android 10/11/12+ 的捕获差异必须分别验证，不能由新版本设备结果推定。

## E. 输入与控制清单

- [ ] 左键点击/拖动映射为触摸，中键 Home，右键 Back；锁屏时右键可先唤醒。
- [ ] 鼠标滚轮、触控板和触摸屏事件保持 pointer ID 稳定。
- [ ] down、move、up、cancel 成对；断线、焦点丢失和 Widget 销毁时清理活动指针。
- [ ] 指针离开视频区域的行为由统一状态机处理，不能累积成 `Too many pointers`。
- [ ] contain/cover、黑边、裁剪、Alignment、DPI、窗口缩放和旋转后的坐标正确。
- [ ] 主屏、已有显示和虚拟显示使用各自实时视频尺寸映射。
- [ ] Flutter 键盘事件只在画面获得焦点时发送到设备。
- [ ] 普通字符和 Android 按键被消费；宿主系统组合键按统一白名单放行。
- [ ] Back、Home、Recent、Power、Wake、Enter、Delete 和音量控制逐项验证。
- [ ] 剪贴板 ACK、文本输入和控制回包不会挂住后续发送队列。
- [ ] 批量触摸只从一个主控 Session 广播，并使用归一化坐标。

## F. Session 与生命周期清单

- [ ] 创建平台客户端不会早于 Flutter Binding 初始化平台通道。
- [ ] Session 状态使用同一状态机，重复 start/stop 幂等或返回明确错误。
- [ ] View 销毁不隐式关闭 Session；Manager 负责 Session 所有权。
- [ ] 每个 Session 独立持有 SCID、端口、socket、解码器、Texture 和控制器。
- [ ] 单个 Session 失败不影响其他设备或其他虚拟屏。
- [ ] USB 掉线、Wi-Fi 切换、设备重启和应用后台恢复按统一重连策略执行。
- [ ] 重连不重复注册输入、音频焦点、监听器或 Texture。
- [ ] 异步回调在 dispose 后不调用已关闭 StreamSink、Surface 或 MethodChannel。
- [ ] 插件 detach、Flutter 热重启和宿主窗口关闭后原生资源归零。
- [ ] 所有异步操作有超时、取消和结构化错误码。

## G. Flutter UI 与嵌入清单

- [ ] `ScrcpyView` 能放入页面、Dialog、Tab、Grid 和自定义窗口。
- [ ] 布局按父级 `LayoutBuilder` 的可用尺寸响应，不按设备类型判断。
- [ ] 窄窗口中的标题、状态和按钮分层或换行，不出现 RenderFlex overflow。
- [ ] 视频始终保持目标宽高比，预览尺寸不反向修改虚拟屏像素尺寸。
- [ ] 全屏、聚焦和滚动不隐式重连或改变画质。
- [ ] 虚拟屏默认保持竖屏；用户可以显式调整像素尺寸、DPI 和方向。
- [ ] 页面显示连接中、首帧等待、音频不可用、重连次数和明确错误。
- [ ] Demo 只调用公开 API，第三方 Flutter 工程可以复制相同接入方式。

## H. 多会话与设备墙清单

- [ ] 同设备多虚拟屏和跨设备 Session 可以同时运行。
- [ ] 网格列数、卡片尺寸和聚焦视图随窗口宽度调整。
- [ ] 音频焦点切换后只有当前窗口出声。
- [ ] 逐窗口画质修改只重建目标 Session，并明确提示会重连。
- [ ] 批量控制组只有一个主控，目标加入和移除不会留下旧广播关系。
- [ ] 一个目标不支持某项控制时单独报告，不中止整组任务。
- [ ] 离屏、最小化和不可见窗口的调度策略可配置并有性能指标。

## I. 权限、安全与发行清单

- [ ] 网络、局域网、mDNS、USB、蓝牙和通知权限只在对应功能需要时申请。
- [ ] 用户拒绝权限后保留手动连接或其他可用入口。
- [ ] Android 前台服务、iOS 本地网络、macOS 沙盒、Linux udev 等限制分别记录。
- [ ] 原生库、ADB、scrcpy-server 和许可证随目标产物打包。
- [ ] Debug 与 Release 都在干净工程构建，检查 ABI、架构和最小系统版本。
- [ ] 日志、诊断导出和崩溃报告默认脱敏。
- [ ] 不将网络调试端口、私钥或远程控制接口暴露给未授权调用方。

## J. 每个平台的最小验收顺序

1. 插件注册、创建默认客户端、空设备列表和安全退出。
2. ADB 发现、授权、shell、push/pull 与 forward。
3. scrcpy server 部署、视频首帧和停止清理。
4. 点击、拖动、键盘、导航键和剪贴板。
5. 动态尺寸、旋转、断线和重连。
6. 音频播放、静音、焦点切换和失败降级。
7. 虚拟屏、多 Session、截图与录屏。
8. 嵌入式 View、窄屏/宽屏和应用生命周期。
9. 30 分钟单设备稳定性，再执行多设备与压力测试。

每一步都要留下自动化用例或真机记录。前一步的资源清理未通过时，不进入多 Session 测试。

## 平台差异表

| 宿主平台 | ADB | mDNS | 视频 | 音频 | 主要限制 | 当前状态 |
| --- | --- | --- | --- | --- | --- | --- |
| Windows | 官方 platform-tools | `adb mdns services`，延后 | Media Foundation + PixelBuffer Texture | libopus + 系统输出 | D3D11 零拷贝延期 | 主线已实现 |
| Android | ScrcpyForAndroid 原生传输，USB Host 待移植 | 延后 | MediaCodec + SurfaceProducer | 待实现 | 后台限制、OTG 与 USB 权限 | 整条链路重构中 |
| Linux | process 或直接 transport | Avahi/内置发现待选 | VA-API/FFmpeg/GStreamer 待验证 | PipeWire/PulseAudio 待验证 | Wayland 输入与 udev | 未开始 |
| macOS | process 或直接 transport | Bonjour | VideoToolbox | CoreAudio | 沙盒、签名、公证 | 未开始 |
| iOS/iPadOS | 优先网络 ADB | Bonjour | VideoToolbox | AVAudioEngine | USB 与后台、发行限制 | 仅可行性验证 |
| HarmonyOS/OpenHarmony | 待选择成熟平台后端 | 延后 | 平台硬解待验证 | 平台音频待验证 | Flutter OHOS、TLS/socket 与 USB 权限 | 未开始 |
| Web | WebADB/WebUSB 或网关 | Web transport 自身发现或空实现 | WebCodecs | WebAudio | Chromium、安全上下文、后台降频 | 未开始 |

## 平台适配交接模板

```text
平台/系统版本：
Flutter 与工具链版本：
目标设备与 Android 版本：
完成到清单项：
自动化测试：
真机验证：
未支持能力及返回方式：
已知系统限制：
资源清理结果：
下一步：
```

平台代码中的临时绕行必须在交接记录中写明触发条件和移除条件。相同问题第二次出现时，应修正公共状态机或接口，不再为单个平台叠加页面补丁。
