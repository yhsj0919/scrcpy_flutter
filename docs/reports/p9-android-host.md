# P9 Android 宿主原型记录

更新于 2026-09-11。

## 当前实现

- Android 默认客户端使用平台原生 ADB 后端，不依赖外部 `adb` 可执行文件。
- 已接入验证码配对、网络连接、RSA 身份持久化、shell、sync push 和断开。
- scrcpy server 4.1 随插件作为 asset 分发，并释放到应用私有缓存目录。
- server、video socket、control socket 和 ADB 流都由 Kotlin 会话统一持有。
- H.264 包在原生线程读取后直接送入异步 `MediaCodec`，Dart 不再转发视频包。
- `MediaCodec` 输出到 Flutter `SurfaceProducer`；画面尺寸变化同步更新 Texture、Session 和输入坐标。
- 基础触摸、按键、文本、剪贴板、启动应用和虚拟屏调整继续使用现有 scrcpy 控制消息。
- 启动失败、主动停止、视频断流和插件卸载均进入同一资源清理路径。

## 已删除的旧链路

- 仓库内 `flutter_adb` 副本。
- Dart ADB 协议到 Android 视频 socket 的转发。
- 逐包 MethodChannel 视频投喂。
- 临时 native socket forward 和运行时后端切换参数。

旧实现的延迟数据不能作为当前原生链路的验收结果。

## 当前验收范围

首轮只验收单个网络 ADB 目标：

1. 验证码配对后连接目标设备。
2. 获取设备信息并创建主屏 Session。
3. 首帧显示、连续播放、触摸、Back、Home 和文本输入。
4. 横竖屏切换后画面比例及触摸坐标正确。
5. 主动断开、目标掉线和重新连接后没有假在线 Session。
6. 创建竖屏虚拟屏并启动指定应用。

## 2026-09-11 真机结果

- Android 宿主连接 Samsung SM-S9110（Android 16）成功。
- scrcpy server、video/control socket、H.264 MediaCodec 和 Flutter Texture 链路成功出图。
- 用户确认画面延迟明显改善，当前体验可接受。
- 运行日志达到 936 个解码输出帧，稳定阶段持续保持 `pending=0`、
  `dropped=0`、`decoderLagMs=0`，未发现解码队列积压。
- 同次日志发现控制 socket 曾在 Flutter 主线程写入并触发
  `NetworkOnMainThreadException`；控制发送已改为每 Session 独立串行线程，
  等待下一轮触摸与按键复验。

## 延后项目

- Android mDNS 已接入原生 `NsdManager`：并行发现 `_adb-tls-pairing._tcp` 和 `_adb-tls-connect._tcp`，串行解析服务以兼容旧系统限制，并维护新增、端口更新和移除后的解析缓存。公共 `discoverMdnsServices()`、`watchMdnsServices()`、验证码配对及配对后连接端口匹配无需平台分支，等待无线调试真机验证。
- Android USB Host 已实现：枚举 ADB interface、动态申请 USB 权限、bulk endpoint 输入输出、RSA 授权握手、按 `usb:<deviceId>` 路由 Session，以及拔出设备后的连接清理。USB 与网络设备共用 `AdbDevice` 和按 serial 路由的上层 API，等待 OTG 真机验证。
- Android USB Host 单向真机验证已通过：Samsung 宿主通过 OTG 连接 Xiaomi 目标设备后，可以完成 USB 权限、ADB 授权和基本操作。反向使用 Xiaomi 宿主连接 Samsung 时，系统可能启动 Samsung 换机助手，或协商为 Samsung Host、Xiaomi Peripheral，因而出现反向连接 Xiaomi ADB 的现象。这属于 USB-C Dual Role 和厂商 USB 策略限制；普通第三方应用只能使用系统已经分配给本机的 Host 角色和 ADB interface，不能可靠强制交换数据角色。
- Android 原生音频链路已实现，主屏、虚拟屏和设备墙焦点切换待真机验证。
- Android 截图已通过 PixelCopy 直接从解码 Surface 获取 PNG，待真机验证。
- Android MP4 录屏已使用 H.264 编码包直写实现，不进行二次编码，待真机验证文件收尾与播放器兼容性。
- Android 控制回包读取已接入，支持设备剪贴板文本事件并正确消费 ACK/UHID 消息，待真机验证双向剪贴板。
- Android 剪贴板写入已使用序号等待 ACK，超时和 Session 关闭会释放全部等待任务。
- Android 视频统计已接入 `ScrcpyVideoState`，包含接收字节、数据包、渲染帧、FPS 和解码输入丢弃数。
- Android ADB 已补齐 pull、安装和卸载入口；pull 使用同目录临时文件，失败时清理且不会留下半成品目标文件。
- Android shell 现在返回真实退出码，文件存在判断、权限错误和应用命令不再被误判为成功。
- Android 应用名称和视频编码器查询改由平台后端运行内置 scrcpy server，避免 Dart 因无法访问 APK 私有资源路径而跳过增强。
- Android ADB 接口已移除 `noSuchMethod` 兜底；process-only 的长运行命令和 host forward 现在返回结构化 `unsupportedCapability`。
- 修正 ADB sync pull 的 `DONE` 解析：状态字段不再被误当成 payload 长度读取。
- Android ADB 的原生 `PlatformException` 已统一映射为 `AdbException`，连接、配对和命令错误保持机器可读错误码。
- Android 控制器在 Session 断开时立即转为不可用并清理剪贴板等待，避免界面仍显示可控制但写入死连接。
- Android 录屏与视频 Session 已拆分失败域；旋转、动态尺寸或写盘失败只安全结束录屏，不中断画面和控制。
- Android 音频统计已接入 `ScrcpyAudioState`，包含音频包、字节、解码包、播放缓冲和丢弃缓冲。
- Android 内置 scrcpy-server 释放前后均校验固定 SHA-256；缓存损坏或版本不符会使用临时文件安全替换。
- Android 音频流结束或解码线程异常会独立通知 Dart 音频控制器并释放焦点，不再把音频故障伪装成仍在播放，也不会中断视频 Session。
- Android 视频 codec 选择现已贯穿 Dart、scrcpy server 和 MediaCodec，支持按设备能力选择 H.264、H.265 或 AV1；H.265/AV1 待真机验证。当前 Android MP4 直写录屏仅接受 H.264，其他 codec 会明确拒绝而不影响画面。
- Android 宿主保留 ADB 连接意图或存在活动 Session 时会运行 `connectedDevice` 类型前台服务，并持有 CPU WakeLock 与高性能 Wi-Fi Lock。视频 Session 意外断开不会提前释放运行保障，重连会按保存端点重建底层 ADB；显式断开或插件卸载才统一释放。锁屏超过 30 秒保持和自动恢复已完成真机验证。
- 文件管理已完全移除嵌套 `sh -c`、`find`、glob 和管道，统一使用 `ls`、`stat`、`mkdir`、`mv`、`rm`、`test` 的结构化 argv；避免 Android toybox、厂商 shell 与 Windows process ADB 产生不同转义结果。目录只枚举当前一级，符号链接目录和根目录不会被递归进入；远程错误保留具体输出。当前不支持名称中包含换行符的极端文件名。
- Android 原生连接器创建虚拟屏后会执行配置中的 `launchApplication`，与桌面连接器保持一致；启动失败会关闭整个未完成 Session，避免设备管理页面留下可控制但黑屏的空虚拟显示。
- 多设备、设备墙及 30 分钟稳定性测试。
- Wireless Debugging 动态端口自动跟踪。

## 锁屏与后台待验证

1. 建立网络 ADB 主屏 Session，连续播放动态画面。
2. 锁定 Android 宿主屏幕并保持 2 分钟，确认被控端 scrcpy server 没有退出。
3. 解锁后画面继续更新，触摸立即可用，Session 没有重复创建。
4. 再锁屏 10 分钟后解锁，检查是否出现假在线、音视频积压或重复音频。
5. 会话运行时将应用切到后台再恢复，验证结果同上。
6. 主动断开 ADB，确认常驻通知消失；重新连接后通知恢复。

## 上游与更新

ADB TLS/配对和流实现基于 ScrcpyForAndroid 的 Apache-2.0 代码。来源、基线和同步规则见
`android/third_party/scrcpy_for_android/UPSTREAM.md`。更新时应整体对比 ADB transport、配对、
scrcpy socket 和解码生命周期，避免只移植单个问题补丁。
