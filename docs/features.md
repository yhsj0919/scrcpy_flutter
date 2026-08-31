# 功能范围与优先级

更新于 2026-08-31。

本文档描述产品功能范围和优先级；具体实现步骤、完成证据和复选框以[可执行开发计划](development-plan.md)为准。

## 优先级定义

- **S0 首版核心**：先完成，形成“连接设备—查看画面—完整基础控制”的闭环。
- **S1 早期增强**：单设备稳定后优先实现，包括常用 ADB 管理和安全的批量 ADB 操作。
- **S2 设备墙**：多会话、资源调度、批量控制和多开页面。
- **S3 长期能力**：高级管理、监控、自动化和更多 scrcpy 功能。

## S0：首版核心

### ADB 连接

- USB 本地设备发现、授权状态和连接状态。
- 手动输入 `IP:端口` 的网络设备连接与断开。
- Android Wireless Debugging 配对码连接：发现/输入配对地址，执行 `adb pair`，再连接调试地址。
- 已连接、未授权、离线、配对失败、连接失败等明确状态和错误提示。
- 连接信息持久化时不得保存配对码；设备序列号在日志中默认脱敏。

### 当前画面

- 连接后启动匹配版本的 scrcpy server。
- H.264 低延迟画面、保持比例、横竖屏和窗口自适应。
- 启动/停止、断线、重连、旋转和动态分辨率处理。
- 画质配置：最大分辨率、最大 FPS、视频码率、编解码器和编码器选择。
- 运行中显示实际分辨率、FPS、码率、解码器和连接状态。

### scrcpy 基本控制

- 鼠标/单指触摸的 down、move、up、cancel。
- 多指触摸所需的 pointer ID 和事件模型。
- 点击、长按、拖动、滑动、滚动和捏合等模拟触摸手势。
- Back、Home、Recent Apps、Power、Wake、音量、Enter、Delete 和常用 Android keycode。
- 键盘输入、文本注入和剪贴板同步。
- 屏幕开关、旋转、保持唤醒等常用 scrcpy 控制。
- 正确处理黑边、裁剪、缩放、DPI 和横竖屏坐标映射。

## S1：早期增强

### 设备列表和设备详情

- USB、网络和已配对设备的统一列表。
- 设备名称、品牌、型号、Android 版本、SDK、ABI、序列号脱敏值。
- 屏幕尺寸、密度、方向、连接类型、IP 地址和 ADB 状态。
- 电池电量、充电状态、温度、存储容量、运行时间等基本状态。
- 刷新时间、获取失败原因和各字段的来源命令。

### 文件管理

- 浏览目录、进入上级目录、刷新、排序和基本文件属性。
- `adb push` 上传、`adb pull` 下载、创建目录、重命名和删除。
- 长任务进度、取消、失败重试和逐文件结果。
- 所有路径使用结构化参数，禁止通过未转义字符串拼接 shell 命令。
- 删除、覆盖等破坏性操作必须显示准确目标并要求确认。

### 设备运行状态

- 电池、温度、CPU、内存、存储、网络和 uptime 概览。
- 前台应用、已安装应用和关键进程概览。
- 可配置刷新间隔；设备墙中必须限制轮询频率，避免 ADB 查询本身造成负载。

### 早期批量 ADB 操作

- 多设备安装 APK，支持覆盖安装等显式选项。
- 多设备卸载应用，明确是否保留数据。
- 批量启动/停止应用、清理应用数据和执行允许列表中的常用操作。
- 操作前显示目标设备和参数，支持并发上限、取消、超时、重试。
- 每台设备独立显示 queued/running/succeeded/failed/cancelled 结果。
- 不提供默认开启的任意 shell 群发；高风险操作需要额外确认。

## S2：设备墙与多开

### 设备墙

- 多 Session 独立生命周期和故障隔离。
- 响应式网格、分页/滚动、聚焦设备和全屏。
- 根据聚焦、可见和离屏状态动态调整分辨率、FPS 和解码资源。
- 8 台稳定目标，16 台压力测试目标；最终上限以实测报告为准。

### 批量控制

- 在明确选中的设备集合上广播导航键、启动应用和安全的控制动作。
- 触摸广播必须考虑不同分辨率和宽高比，使用归一化坐标并显示不兼容设备。
- 支持暂停广播、紧急停止、单设备脱离和逐设备执行结果。
- 默认不广播文本、密码、剪贴板和破坏性操作。

### 应用多开与自适应页面

- 利用 scrcpy virtual display/new display 在同一设备创建额外显示会话。
- 指定应用启动到虚拟显示，支持尺寸、DPI、系统装饰和 IME 策略。
- Flutter 页面根据一个设备的多个 display/session 自动布局。
- 主屏和虚拟显示分别维护视频尺寸、控制坐标、生命周期和错误状态。
- 该能力依赖设备系统版本和厂商实现，必须先做兼容性矩阵。

## S3：长期能力与平台扩展

- 音频转发和聚焦设备音频。
- 截图、录制和媒体导出。
- 相机镜像、游戏手柄、UHID/AOA/OTG 等高级 scrcpy 能力。
- 应用详情、权限、日志、进程和性能分析。
- 任务模板、定时任务和受控自动化。
- Linux、macOS 主机支持。
- Android 宿主：优先评估 Android 手机/平板通过 USB Host 或网络 ADB 管理另一台 Android 设备。
- HarmonyOS/OpenHarmony 宿主：只作为控制端连接 Android，不把 HarmonyOS 设备作为 scrcpy 被控端。
- iOS 宿主：分别评估网络 ADB 和受系统许可限制的 USB 配件访问，不预先承诺可发布性。
- Web：优先评估 Chromium 系浏览器的 WebUSB + WebCodecs 路线，以及通过桌面代理/网关连接设备的兼容路线。

## 后期平台可行性边界

### Android 宿主

技术上可行性较高。Android 官方 USB Host API 可以枚举 USB 设备、申请用户授权并直接读写 USB endpoint，因此可以实现不依赖本机 `adb` 可执行文件的 ADB client。网络 ADB 和配对协议同样可由应用实现。视频可使用 Android MediaCodec 或 FVP 输出到 Flutter texture。

需要验证：双 Android 设备的供电/OTG 模式、USB 权限生命周期、ADB RSA 密钥安全存储、后台限制、多设备 Hub，以及目标设备同时充电的问题。

### iOS/iPadOS 宿主

技术和发行风险较高。不能假设存在可执行的系统 `adb`。网络 ADB 可以理论上由应用实现完整协议；USB 访问取决于 Apple 提供的配件框架、设备能力、系统版本和审核/授权条件。只有在真机和发布条件验证通过后才进入正式开发。

### HarmonyOS/OpenHarmony 宿主控制 Android

目标范围严格限定为：HarmonyOS/OpenHarmony 手机上的 Flutter 应用作为 ADB/scrcpy 客户端，连接和控制 Android 设备；不实现控制 HarmonyOS，也不在 HarmonyOS 上运行 scrcpy server。

网络路线具有较高可行性：HarmonyOS 提供 TCP socket 和 mDNS 等网络能力，可以承载网络 ADB、Wireless Debugging 配对和 scrcpy socket。USB 路线需要验证普通应用能否获得所需 USB DDK/USB Host 权限；官方 USB 能力包含设备枚举、接口声明和 bulk/control transfer，但相关系统能力与权限可能限制发行范围。视频方面，FVP 已包含 OHOS 平台支持，可作为优先验证后端。

需要单独验证 Flutter OHOS 工具链、平台插件、USB 权限、ADB RSA/TLS、FVP texture、后台限制及应用市场发行条件。USB 权限不满足时，允许只支持网络 ADB。

参考资料：

- HarmonyOS USB 服务：<https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/usb-overview-V13>
- HarmonyOS USB DDK：<https://developer.huawei.com/consumer/en/doc/harmonyos-references/capi-usb-ddk-api-h>
- HarmonyOS Socket API：<https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-api>
- FVP OHOS 支持：<https://github.com/wang-bin/fvp>

### Web

技术上存在可行路线：Tango ADB 已提供浏览器/Node.js 的 ADB 与 scrcpy 客户端实现；WebCodecs 可低层、硬件加速地解码 H.264 等编码帧；WebUSB 可连接 USB 设备。

但 WebUSB 不是 Baseline，要求 HTTPS 安全上下文，也不被所有主流浏览器支持。因此 Web 首版只能考虑 Chromium 支持矩阵，不能承诺 Safari/Firefox。另保留“Web UI + 本地桌面代理/远程网关”路线，以绕开浏览器不能直接访问设备的问题。

参考资料：

- Android USB Host：<https://developer.android.com/develop/connectivity/usb/host>
- WebUSB：<https://developer.mozilla.org/en-US/docs/Web/API/WebUSB_API>
- WebCodecs：<https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API>
- Tango ADB scrcpy client：<https://tangoadb.dev/scrcpy/>
- Apple AccessoryAccess：<https://developer.apple.com/documentation/AccessoryAccess>

## 不在首版范围

- 任意 ADB shell 群发执行器。
- 无确认的批量卸载、清数据、删除文件、关机或恢复出厂设置。
- 在没有性能报告前承诺 16 台稳定运行。
- 在没有兼容性验证前承诺所有设备支持 virtual display 多开。
- 在未完成真机与发行审核验证前承诺 iOS USB ADB。
- 在 WebUSB 不受支持的浏览器中承诺浏览器直连 USB 设备。
- 把“鸿蒙控制 Android”宣传成“scrcpy 控制鸿蒙”，或在 USB 权限验证前承诺鸿蒙 USB 直连。
