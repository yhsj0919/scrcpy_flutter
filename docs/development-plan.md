# 可执行开发计划与交接清单

更新于 2026-09-02。

本文件是项目开发进度的唯一逐项事实来源。完成一项就将 `[ ]` 改成 `[x]`，并在对应条目下填写日期、提交/文件、验证结果和必要备注。不得只因“代码已经写完”而勾选，必须满足该项的完成判定。

## 使用规则

- `[ ]`：未完成，包含尚未开始、正在实现或尚未通过验证的工作。
- `[x]`：已满足全部完成判定，并留下可复查证据。
- 同一时间原则上只推进一个阶段；阶段内可以并行，但上游验收门未通过时不能宣布下游阶段完成。
- 遇到阻塞时不勾选，在条目下新增 `阻塞：原因、发现日期、解除条件`。
- 行为或范围发生变化时，保留原记录并补充决策日志，不静默改写历史。
- 文件路径、测试命令、日志或性能报告应使用仓库相对路径，便于其他人复现。
- 每次交接前更新“当前交接摘要”和“变更/决策日志”。

## 当前交接摘要

- 当前阶段：P5-A 应用与显示源。
- 当前状态：P0～P4 与 P5-00～P5-06 已完成；Demo 已提供同页新增、排列、切换应用、旋转、动态适应和关闭任意虚拟屏的工作台。P3-05 和 P4-04 长时间稳定性测试按决策延期，仍保持未勾选。
- 下一项：P5-07 scrcpy 音频协议与传输，随后完成 Windows 音频播放与焦点，再进入设备墙。
- 当前阻塞：无；真实批量安装/卸载仍等待专用测试 APK 做补充真机验收，不阻塞 P5。
- 已选基线：Windows、scrcpy 4.1、平台原生解码、网络/USB ADB、H.264；P5 增加 Opus 音频与虚拟显示。
- 当前功能闭环：USB/网络/配对码连接，实时画面，画质配置，scrcpy 基础控制、模拟触摸、剪贴板、设备管理与安全批量包操作。
- 交付形态：从 P0 起按可嵌入 Flutter 插件实现；example 只消费插件公开 API，不承载核心逻辑。
- 已完成增强：设备详情、文件管理、设备/应用 CPU/内存/GPU 状态，以及安装/卸载等批量 ADB 操作。
- 稳定目标：8 台设备；压力测试目标：16 台设备。
- 后期平台：Android 宿主优先验证；HarmonyOS/OpenHarmony 仅验证“宿主控制 Android”；Web 优先 Chromium；iOS/iPadOS 只在系统与发行条件允许时继续。

---

## P0：工程基线（预计 1–2 天）

阶段完成判定：P0 全部条目勾选，静态检查、测试和 Windows 示例构建均通过。

- [x] **P0-01 环境健康检查**
  - 完成判定：`flutter doctor -v`、`flutter --version`、`adb devices -l` 能在合理时间内返回；确认 Visual Studio C++、Windows SDK、CMake 和 Ninja 可用。
  - 验证证据：将关键版本写入 `docs/environment.md`，不记录设备序列号。
  - 完成日期：2026-08-31
  - 提交/文件：`docs/environment.md`
  - 备注：Flutter 3.47.2、Dart 3.13.2、VS 2026、Windows SDK 10.0.26100、CMake 3.22.1、Ninja 1.10.2 已验证；doctor 和设备查询正常返回。`flutter.bat` 锁问题使用同 SDK snapshot 非破坏性绕过。

- [x] **P0-02 固定首版依赖版本**
  - 完成判定：文档和依赖配置明确固定 scrcpy 4.1；记录 server 文件来源、SHA-256 和许可证。
  - 验证证据：`pubspec.lock`、第三方依赖清单及校验值可复查。
  - 完成日期：2026-08-31
  - 提交/文件：`pubspec.yaml`、`example/pubspec.lock`、`docs/third-party-components.md`、`windows/third_party/`
  - 备注：固定 scrcpy server 4.1，server/许可证 SHA-256 可复查；当前 Windows 视频后端为 Media Foundation。

- [x] **P0-03 定义最小公开 API**
  - 完成判定：确定插件入口、能力查询、设备服务、会话配置/状态、错误码、视频控制器、视频 Widget 和输入层的 Dart API；不暴露上游内部对象，宿主无需导入 `lib/src`。
  - 验证证据：API 文档和对应单元测试通过。
  - 完成日期：2026-08-31
  - 提交/文件：`lib/scrcpy_flutter.dart`、`lib/src/`、`docs/public-api.md`、`test/`
  - 备注：能力查询、会话配置/状态、错误码、视频控制器、`ScrcpyVideoView` 和 `ScrcpyInputLayer` 已建立；定向 analyzer 无问题，Session、输入和视频 Widget 测试通过。

- [x] **P0-09 建立独立 ADB 模块边界**
  - 完成判定：ADB 领域 API 与 scrcpy Session 分离；设备发现、连接、配对、shell、sync、包管理和 forward 通过接口提供；ADB 模块不依赖 scrcpy 协议或 Flutter Widget。
  - 验证证据：依赖关系图、package 分析通过、使用 fake ADB backend 的 scrcpy Session 单元测试。
  - 完成日期：2026-08-31
  - 提交/文件：`packages/adb_client/`、`packages/adb_client_process/`、`docs/architecture.md`、`test/scrcpy_flutter_test.dart`
  - 备注：设备发现、连接、配对、shell、sync、包管理和 forward 均为独立接口；package analyzer 无问题，ScrcpySession fake backend 测试通过。暂不拆独立仓库或发布。

- [x] **P0-10 实现桌面 ADB process 后端骨架**
  - 完成判定：封装可执行文件定位、结构化参数、stdin、超时、取消、stdout/stderr、exit code 和脱敏日志；调用方不直接使用 `Process.run('adb', ...)`。
  - 验证证据：fake adb executable 测试覆盖成功、失败、超时、取消和大输出。
  - 完成日期：2026-08-31
  - 提交/文件：`packages/adb_client_process/`、`windows/CMakeLists.txt`、`windows/third_party/platform-tools/`
  - 备注：Windows 首版使用该后端；wire protocol 后端后期按平台增加。fake executable 测试覆盖成功、非零退出、二进制 stdin、超时、取消和 2 MB 输出；设备解析与内置路径测试合计 10 项通过。

- [x] **P0-06 建立插件边界和目录约束**
  - 完成判定：核心逻辑位于插件 `lib/` 和各平台目录；example 只导入公开入口；不存在从 example 反向依赖核心代码。
  - 验证证据：目录说明、公开导出测试和 `rg` 检查结果。
  - 完成日期：2026-08-31
  - 提交/文件：`lib/scrcpy_flutter.dart`、`example/lib/main.dart`、`docs/public-api.md`
  - 备注：example 只导入插件公开入口；核心设备发现和 Session 逻辑全部位于插件/package 内。

- [x] **P0-07 设计多实例与宿主生命周期**
  - 完成判定：记录 ScrcpyClient、Session、Player、texture、ADB transport 和批量任务的所有权；支持同进程多实例；定义 dispose/close/cancel、窗口关闭和异常退出行为。
  - 验证证据：生命周期设计文档和 fake 实现的并发/重复释放测试。
  - 完成日期：2026-08-31
  - 提交/文件：`docs/lifecycle.md`、`lib/src/scrcpy_session.dart`、`test/scrcpy_flutter_test.dart`
  - 备注：禁止只能清理一个会话的全局槽位。所有权和清理顺序已记录，并发 prepare 合并与幂等 dispose 测试通过。

- [x] **P0-08 定义资源打包与覆盖策略**
  - 完成判定：明确 scrcpy server、ADB 和其他二进制由插件如何打包、校验、定位和升级；宿主可显式覆盖，但默认无需安装全局 scrcpy 或 ADB。
  - 验证证据：资源清单、SHA-256、开发/发布构建路径测试。
  - 完成日期：2026-08-31
  - 提交/文件：`windows/CMakeLists.txt`、`example/windows/CMakeLists.txt`、`lib/src/default_scrcpy_client_io.dart`、`docs/third-party-components.md`
  - 备注：ADB、scrcpy server 和许可证进入 Release 产物；ADB/server 路径可由宿主覆盖。默认不修改 PATH、不要求全局安装。

- [x] **P0-04 建立日志与敏感信息规则**
  - 完成判定：日志具备级别、session ID 和模块来源；默认脱敏设备序列号；错误包含机器可读代码。
  - 验证证据：脱敏及错误模型单元测试通过。
  - 完成日期：2026-08-31
  - 提交/文件：`lib/src/scrcpy_log.dart`、`lib/src/scrcpy_error.dart`、`packages/adb_client/lib/src/`、`test/scrcpy_log_test.dart`
  - 备注：日志包含级别、来源和 session ID；结构化 serial、pairing code、password、token 默认脱敏；ADB/Scrcpy 错误码测试通过。

- [x] **P0-05 建立基础质量门**
  - 完成判定：`dart format --output=none --set-exit-if-changed .`、`flutter analyze`、`flutter test` 和 Windows example 构建通过。
  - 验证证据：在本条记录命令结果摘要；后续可迁移到 CI。
  - 完成日期：2026-08-31
  - 提交/文件：`docs/environment.md`、`test/`、`example/test/`
  - 备注：format 36 文件无变化；完整 analyze 无问题；根插件 13 项、Demo 1 项、ADB packages 14 项测试通过；Windows Debug/Release Demo 构建通过且内置资源可运行/校验。

## P1：视频技术验证（预计 3–5 天）

阶段完成判定：真机连续显示 30 分钟，不经 Dart 传输解码后像素，没有不可恢复错误。

- [x] **P1-01 建立 scrcpy 4.1 视频连接**
  - 完成判定：使用匹配 server 建立连接并读取 H.264；SCID、端口和远端路径不与其他会话冲突。
  - 验证证据：连接日志、server 版本校验和首批数据统计。
  - 完成日期：2026-08-31
  - 提交/文件：`lib/src/scrcpy_video_connection*.dart`、`packages/adb_client/lib/src/adb_client_base.dart`、`packages/adb_client_process/lib/src/process_adb_client.dart`、`example/integration_test/native_video_test.dart`
  - 备注：每会话使用随机 31-bit SCID、唯一远端 server 路径和 `adb forward tcp:0`；由插件持有长运行 ADB shell 句柄。ADB forward 的 TCP 假成功不作为 ready，候选连接必须收到并缓存首个 H.264 字节块才返回。真机验证 server 4.1、动态端口、首批数据统计和逆序清理通过。

- [x] **P1-02 Flutter 显示真机首帧**
  - 完成判定：Flutter Widget 显示正确方向、比例和内容的第一帧，并进入稳定播放状态。
  - 验证证据：`docs/reports/p1-video-baseline.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`windows/scrcpy_flutter_plugin.cpp`、`windows/CMakeLists.txt`、`example/integration_test/video_baseline_test.dart`、`docs/reports/p1-video-baseline.md`
  - 备注：Xiaomi Android 16 + Windows Debug 真机 30 秒基线通过。主要采样：连接 644 ms、解码器就绪 916 ms、首帧 1223 ms、862×1920、9.94 FPS、8.98 Mbps、归一化 CPU 10.76%、GPU 平均/峰值 2.88%/3.91%、工作集 462.69 MiB。Debug 内存包含测试与调试运行时开销，详见报告。

- [x] **P1-03 帧级原生低延迟视频后端**
  - 交付物：保留 scrcpy codec/session/frame metadata 的 Dart 拆包器；统一原生解码后端接口；Windows Media Foundation 解码与最新帧 Flutter Texture。
  - 验收：首屏延迟和触摸到画面延迟均可测量；连续操作画面实时刷新；解码积压时只保留最新可解帧；不在 Dart 层逐帧复制 RGBA。
  - 参考：`scrcpy_video_view 0.0.1` 的 macOS 实现使用 scrcpy 12 字节帧头、VideoToolbox、单一 latest pixel buffer 和 `textureFrameAvailable()`；其代码仅支持 macOS，不能直接作为 Windows 依赖。
  - 验证证据：`docs/reports/p1-low-latency.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_video_packet.dart`、`lib/src/native_scrcpy_video.dart`、`windows/scrcpy_flutter_plugin.cpp`、`example/integration_test/control_latency_test.dart`、`docs/reports/p1-low-latency.md`
  - 备注：codec/session/frame 拆包保留 PTS；Windows MF 使用低延迟模式，NV12→RGBA 在独立原生线程执行，单槽队列只保留最新待转换帧，Flutter Texture 不经过 Dart RGBA。Xiaomi 真机 20 次控制到画面指纹变化闭环平均 178.96 ms、P95 318.75 ms、最大 360.01 ms。基于单路 CPU 基线，D3D11 硬解/零拷贝不阻塞单设备 P1，但列为 P6 八设备验收前置优化。

- [x] **P1-04 验证旋转和动态分辨率**
  - 完成判定：横竖屏切换不会永久黑屏或崩溃；宽高比和 texture 生命周期正确。
  - 验证证据：`docs/reports/p1-rotation.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_video_connection_io.dart`、`lib/src/native_scrcpy_video.dart`、`test/native_scrcpy_video_test.dart`、`example/integration_test/rotation_video_test.dart`、`docs/reports/p1-rotation.md`
  - 备注：scrcpy 4.1 重复 session 尺寸事件会触发旧 Texture 串行释放和按新宽高重建。Xiaomi Android 16 真机连续旋转 20/20 次通过，尺寸在 286×640 与 640×286 间正确切换，每次均取得 3–8 个显示帧；结束后旋转设置、ADB forward 和 server 进程均已恢复/清理。

- [x] **P1-05 视频稳定性验收**
  - 完成判定：连续播放 30 分钟，无持续延迟增长、资源明显泄漏或不可恢复错误。
  - 验证证据：`docs/reports/p1-video-spike.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`example/integration_test/video_stability_test.dart`、`windows/scrcpy_flutter_plugin.cpp`、`docs/reports/p1-video-spike.md`
  - 备注：Rockchip Android 15 + Windows Debug 连续 30 分钟通过，全程 ready。工作集增长 36.13 MiB、私有内存增长 24.93 MiB，峰值 488.23/463.10 MiB，期间多次回落且无持续失控增长。结束后 ADB forward、server 进程和远端临时 jar 均为 0。设备画面大部分时间静止，高动态内容压力留待 P6。

## P2：ADB 连接与会话生命周期（预计 5–8 天）

阶段完成判定：同一设备重复启停 50 次，不残留 ADB forward、server 进程、远端临时文件和 Flutter texture。

- [x] **P2-01 ADB 设备发现与状态解析**
  - 完成判定：统一发现 USB 和已连接网络设备，区分 authorized、unauthorized、offline 状态，解析设备信息并默认脱敏序列号。
  - 验证证据：覆盖常见 `adb devices -l` 输出的单元测试。
  - 完成日期：2026-09-01
  - 提交/文件：`packages/adb_client/lib/src/adb_device.dart`、`packages/adb_client_process/lib/src/adb_devices_parser.dart`、`packages/adb_client_process/test/adb_devices_parser_test.dart`、`example/lib/main.dart`
  - 备注：统一解析 USB 和网络设备，覆盖 device、unauthorized、offline、recovery、bootloader、sideload、no permissions 和 unknown；型号下划线已规范化，序列号默认使用稳定哈希脱敏。Demo 仅允许可用设备进入画面页，并为其他状态显示中文原因。

- [x] **P2-06 网络 ADB 连接管理**
  - 完成判定：支持输入 `IP:端口` 执行 connect/disconnect，具有超时、取消、重复连接处理和明确错误码。
  - 验证证据：`docs/reports/p2-network-adb.md`。
  - 完成日期：2026-09-01
  - 提交/文件：`packages/adb_client/lib/src/adb_endpoint.dart`、`packages/adb_client_process/lib/src/process_adb_client.dart`、`packages/adb_client_process/test/process_adb_client_test.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`docs/reports/p2-network-adb.md`
  - 备注：已完成地址解析、连接/断开、15 秒默认可配置超时、取消、错误码和诊断脱敏。Windows + ZC-3588A 网络真机验证通过重复连接、断开、重复断开、恢复连接、设备 ready 状态及错误端点拒绝。真实 ADB 对重复断开返回非零退出码和 `no such device`，适配层仅对此明确语义按幂等成功处理。

- [x] **P2-07 Wireless Debugging 配对码连接**
  - 完成判定：支持输入/发现配对地址和配对码执行 `adb pair`，成功后连接调试地址；配对码不写日志、不持久化。
  - 验证证据：`docs/reports/p2-wireless-pairing.md`。
  - 完成日期：2026-09-01
  - 提交/文件：`packages/adb_client/lib/src/adb_mdns_service.dart`、`packages/adb_client_process/lib/src/adb_mdns_parser.dart`、`packages/adb_client_process/lib/src/process_adb_client.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`docs/reports/p2-wireless-pairing.md`
  - 备注：已通过 `AdbToolkit.pair` 实现配对、mDNS pairing/connect 服务发现与 Demo 验证码配对表单；选择配对服务会自动匹配同主机变化后的最新连接端口。配对码输入隐藏，ADB 诊断参数已脱敏且不持久化。自动化覆盖成功、错误码、过期、取消、IPv4/IPv6 和端口变化；2026-09-01 用户确认手工真机验证通过。

- [x] **P2-08 统一连接设备列表**
  - 完成判定：USB、网络、已配对/已连接设备使用统一模型，展示连接类型、状态、显示名和最后更新时间。
  - 验证证据：`docs/reports/p2-unified-device-list.md`。
  - 完成日期：2026-09-01
  - 提交/文件：`packages/adb_client/lib/src/adb_device.dart`、`packages/adb_client_process/lib/src/adb_devices_parser.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`test/scrcpy_flutter_test.dart`、`example/test/widget_test.dart`、`docs/reports/p2-unified-device-list.md`
  - 备注：在线设备以 `adb devices -l` 为权威来源，mDNS connect 服务补充 `paired` 状态；pairing 广播不进入列表。同一服务端口变化取最新值，在线端点去重。所有条目记录最后发现时间；已配对设备提供连接按钮，在线网络设备提供断开按钮。

- [x] **P2-02 server 部署与版本校验**
  - 完成判定：部署固定 server，启动前验证版本匹配，失败时提供明确错误码。
  - 验证证据：匹配和不匹配版本测试。
  - 完成日期：2026-09-01
  - 提交/文件：`lib/src/default_scrcpy_client_io.dart`、`lib/src/scrcpy_video_connection*.dart`、`test/scrcpy_server_resource_test.dart`、`windows/CMakeLists.txt`
  - 备注：内置 server 固定为 4.1，启动会话前校验存在性和官方 SHA-256，不匹配分别返回 `resourceMissing`/`resourceInvalid`；成功校验在 connector 生命周期内缓存。宿主显式覆盖 server 路径时只检查存在性，不强制官方哈希。Windows Debug 构建产物与源码资源 SHA-256 均为 `DEACB991...8850CAE`。

- [x] **P2-03 会话状态机**
  - 完成判定：实现 idle/starting/streaming/stopping/error/disconnected，异步竞争不会导致重复资源释放或状态倒退。
  - 验证证据：并发 start/stop/dispose 单元测试。
  - 完成日期：2026-09-01
  - 提交/文件：`lib/src/scrcpy_session.dart`、`lib/src/scrcpy_client.dart`、`lib/src/scrcpy_video_connection*.dart`、`test/scrcpy_flutter_test.dart`、`example/lib/main.dart`
  - 备注：Session 已实际拥有视频连接，覆盖 idle/preparing/ready/starting/streaming/stopping/disconnected/error/disposed；并发 prepare/start/stop 合并为同一操作，意外 socket 结束进入 disconnected，启动期间 stop/dispose 不会被迟到结果改回 streaming。测试覆盖并发启停、意外断线、准备中 dispose 和连接建立前 dispose。

- [x] **P2-04 资源所有权与清理**
  - 完成判定：每个 Session 独立拥有 SCID、端口、远端路径、进程、socket、Player 和 texture；正常停止及异常退出均可清理。
  - 验证证据：资源表和异常注入测试。
  - 完成日期：2026-09-01
  - 提交/文件：`docs/lifecycle.md`、`lib/src/scrcpy_session.dart`、`lib/src/scrcpy_video_connection_io.dart`、`lib/src/native_scrcpy_video.dart`、`test/native_scrcpy_video_test.dart`、`test/scrcpy_flutter_test.dart`
  - 备注：每个 Session 使用独立随机 SCID、动态端口和远端路径；Connection 拥有 forward、server 进程及视频/控制 socket，Controller 拥有原生解码器和 Texture。部分 socket 建立失败会关闭已建立 socket；任一 close/dispose 步骤失败仍继续清理后续资源。异常注入验证原生 Texture dispose 失败时 Connection 仍关闭，启动期间 dispose 也会回收迟到连接。资源表见 `docs/lifecycle.md`。

- [x] **P2-05 重复启停验收**
  - 完成判定：同一设备连续启动/停止 50 次全部完成，结束后无项目创建的残留资源。
  - 验证证据：`docs/reports/p2-lifecycle.md`。
  - 完成日期：2026-09-01
  - 提交/文件：`example/integration_test/native_video_test.dart`、`test/scrcpy_flutter_test.dart`、`docs/reports/p2-lifecycle.md`
  - 备注：Windows + ZC-3588A（Android 15）真机最终连续 50 轮全部取得解码帧并正常停止；每轮验证原生 Texture ID 已释放。结束后 `localabstract:scrcpy_*` forward、scrcpy server 进程和远端临时 jar 计数均为 0。另保留一次间歇性失败记录，后续由 P1-05 长稳测试继续覆盖。

## P3：scrcpy 控制闭环（预计 6–9 天）

阶段完成判定：横竖屏与窗口缩放下输入映射准确，控制连接连续操作无协议错位。

- [x] **P3-01 scrcpy 4.1 控制消息序列化**
  - 完成判定：覆盖触控、按键、滚轮和文本所需消息，字段与 4.1 server 单元测试/源码一致。
  - 验证证据：二进制 fixture 测试。
  - 完成日期：2026-09-01
  - 提交/文件：`lib/src/scrcpy_control_message.dart`、`test/scrcpy_control_message_test.dart`
  - 备注：按上游 4.1 的二进制 fixture 实现 32 字节触摸、21 字节滚轮、14 字节按键和 UTF-8 文本消息；坐标、尺寸、压力、64 位 pointer ID、按钮和定点滚动量均按大端序编码。

- [x] **P3-02 Flutter 输入覆盖层**
  - 完成判定：实现 pointer down/move/up/cancel、鼠标按键、滚轮和键盘焦点，不阻断视频布局。
  - 验证证据：Widget 测试和事件日志。
  - 完成日期：2026-09-01
  - 提交/文件：`lib/src/scrcpy_input.dart`、`example/lib/main.dart`、`test/scrcpy_input_test.dart`
  - 备注：pointer down/move/up/cancel/hover/scroll 覆盖层已接入 Demo Texture，并通过同一 SCID/ADB forward 的第二条 control socket 发送；Focus 已映射 Escape、Home、方向、Enter、Backspace、Delete、Tab、Space、音量及字母数字键。Ctrl/Alt/Meta 等正常系统组合键继续放行；Windows 系统音量键拦截方案因实机验证无效已撤销。

- [x] **P3-03 坐标映射**
  - 完成判定：正确处理 contain/cover、黑边、裁剪、DPI、窗口缩放、横竖屏和动态视频尺寸。
  - 验证证据：`docs/reports/p3-coordinate-mapping.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_input.dart`、`test/scrcpy_input_test.dart`、`example/lib/main.dart`、`docs/reports/p3-coordinate-mapping.md`
  - 备注：纯函数和 Widget 测试覆盖 contain/cover、可见四角、黑边、源裁剪、非居中 Alignment、窗口缩放、逻辑 DPI 等比例变化、横竖屏动态尺寸及 NaN/Infinity 防御。Demo 通过当前视频宽高重建输入层；P1-04 真机 20 次旋转为动态尺寸来源提供集成证据。根包 37 项测试全部通过。

- [x] **P3-04 基础导航与输入**
  - 完成判定：点击、长按、拖动/滑动、滚轮、Back、Home、Recent Apps、Power、Wake、音量、Enter、Delete 和基础键盘输入可用。
  - 验证证据：`docs/reports/p3-basic-control.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_input.dart`、`example/lib/main.dart`、`example/integration_test/basic_control_test.dart`、`test/scrcpy_input_test.dart`、`docs/reports/p3-basic-control.md`
  - 备注：Windows + ZC-3588A（Android 15，网络 ADB）真机通过完整基础控制序列；点击、长按、拖动、滚轮、导航、音量、Enter/Delete、文本、电源和唤醒消息连续发送后，视频由 2 帧推进至 43 帧且会话保持 streaming。Demo 增加独立设备控制卡片和文本发送入口；根包 40 项测试全部通过。

- [x] **P3-06 多指与手势模拟**
  - 完成判定：正确维护多个 pointer ID，支持双指缩放等基础多指事件，取消/抬起不会遗留触点。
  - 验证证据：`docs/reports/p3-multitouch.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_input.dart`、`example/lib/main.dart`、`example/integration_test/basic_control_test.dart`、`test/scrcpy_input_test.dart`、`docs/reports/p3-multitouch.md`
  - 备注：输入覆盖层透传 Flutter 原始 pointer ID；新增公开 `ScrcpyGestureSimulator.pinch()`，按归一化中心、方向、跨度、步数和时长生成成对双触点序列，并在 finally 中释放已按下触点。Demo 提供双指放大/缩小按钮。ZC-3588A 真机连续执行放大与缩小后视频 2→41 帧且会话保持稳定；并发 ID、MOVE、UP、CANCEL 与非法路径均有测试覆盖。

- [x] **P3-07 剪贴板与文本输入**
  - 完成判定：支持基础文本注入和可开关的双向剪贴板同步，避免自身写入导致循环同步。
  - 验证证据：`docs/reports/p3-clipboard.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_clipboard.dart`、`lib/src/scrcpy_control_message.dart`、`lib/src/scrcpy_input.dart`、`lib/src/scrcpy_video_connection_io.dart`、`example/lib/main.dart`、`example/integration_test/basic_control_test.dart`、`test/scrcpy_clipboard_test.dart`、`test/scrcpy_control_message_test.dart`
  - 备注：按 scrcpy 4.1 官方协议实现 GET/SET_CLIPBOARD、设备 Clipboard/ACK 分片解析和 256 KiB 上限。内置 server 关闭自身 clipboard autosync，由插件提供可开关双向同步、显式推送/拉取、发送并粘贴及 COPY/CUT，避免双重同步语义；最近来源值抑制自身回环。ZC-3588A 真机完成中英文、换行、特殊字符的 SET→ACK→GET 精确读回。密码及敏感剪贴板不进入日志。

- [x] **P3-08 视频画质配置**
  - 完成判定：API/UI 支持最大尺寸、最大 FPS、视频码率、H.264/H.265/AV1 能力选择及编码器选择；不支持时明确回退或报错。
  - 验证证据：`docs/reports/p3-video-quality.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_session.dart`、`lib/src/scrcpy_video_capabilities.dart`、`lib/src/scrcpy_client.dart`、`lib/src/scrcpy_video_packet.dart`、`lib/src/native_scrcpy_video.dart`、`lib/src/scrcpy_video_connection_io.dart`、`example/lib/main.dart`、`example/integration_test/video_quality_test.dart`、`test/scrcpy_video_capabilities_test.dart`
  - 备注：API/UI 支持最大尺寸、FPS、码率、H.264/H.265/AV1 和设备编码器选择；使用内置 scrcpy 4.1 `list_encoders` 真机探测并区分硬件/软件、vendor 和 alias。当前 Windows 原生 Texture 解码明确仅支持 H.264，选择 H.265/AV1 时在渲染前返回 `unsupportedCapability`，不会黑屏或花屏。ZC-3588A 两档 H.264 指标对比通过。

- [ ] **P3-05 控制稳定性验收**
  - 完成判定：横竖屏各连续操作 10 分钟，无坐标漂移、卡死和控制协议错位。
  - 验证证据：`docs/reports/p3-control.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：⏸ 2026-09-02 按开发决策延期；先推进功能，不阻塞 P4/P5，后续集中执行长时间测试。

## P4：单设备稳定版与 S1 管理能力（核心 4–6 天，S1 增强 6–12 天）

阶段完成判定：单设备连续运行 2 小时，拔插、断流、旋转和应用退出均能恢复或明确失败。

- [x] **P4-01 USB 热插拔检测**
  - 完成判定：设备加入、离开、unauthorized/offline 状态能更新到 Flutter。
  - 验证证据：`docs/reports/p4-device-monitor.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_device_monitor.dart`、`example/lib/main.dart`、`example/integration_test/device_monitor_test.dart`、`example/integration_test/usb_hotplug_test.dart`、`test/scrcpy_device_monitor_test.dart`
  - 备注：插件公开轮询监视器并输出 added/removed/changed 快照，Demo 每 2 秒自动更新。单元测试覆盖 USB unauthorized→device、网络 offline 加入和设备移除；ZC-3588A 网络断开/重连及 23127PN0CC USB 物理拔出/插回真机测试均通过。

- [x] **P4-02 断线与重连策略**
  - 完成判定：区分用户停止与意外断线；重连有次数、退避和取消机制，不产生重复会话。
  - 验证证据：`docs/reports/p4-reconnect.md`。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_session.dart`、`example/lib/main.dart`、`example/integration_test/reconnect_test.dart`、`test/scrcpy_flutter_test.dart`
  - 备注：Session 支持默认关闭、可配置次数/指数退避/最大间隔的重连策略；用户 stop/dispose 立即唤醒并取消等待。替代连接通过 `reconnectedConnections` 输出，Demo 自动重建 Texture、输入和剪贴板通道。23127PN0CC 真机精确终止当前 SCID server 后自动取得新 SCID 并恢复出帧。

- [x] **P4-03 示例应用单设备页面**
  - 完成判定：仅使用插件公开 API，具备设备选择、启动/停止、画面、基础控制、状态、错误和诊断信息；example 内无协议、ADB 或解码核心逻辑。
  - 验证证据：example Windows 构建与人工验收。
  - 完成日期：2026-09-02
  - 提交/文件：`example/lib/main.dart`、`example/test/widget_test.dart`、`docs/reports/p4-single-device-demo.md`
  - 备注：设备列表与单设备页面分别依赖 `adb_client` 和 `scrcpy_flutter` 的公开 API；覆盖启动/停止、Native Texture 画面、鼠标键盘/多点触摸、导航键、文本、剪贴板、画质参数、会话错误、帧统计及连接诊断。Windows Release 构建成功，并确认产物包含内置 ADB、所需 DLL 和 scrcpy-server 4.1。

- [ ] **P4-04 两小时稳定性验收**
  - 完成判定：连续显示和间歇控制 2 小时，无崩溃、显著泄漏或持续延迟增长。
  - 验证证据：`docs/reports/p4-single-device.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：⏸ 2026-09-02 按开发决策延期；与其他长时间测试集中执行，不阻塞功能开发。

- [x] **P4-05 设备基础详情**
  - 完成判定：提供品牌、型号、Android/SDK、ABI、屏幕、密度、连接类型、电池、存储和 uptime；单字段失败不导致整页失败。
  - 验证证据：数据来源文档、解析测试和真机页面。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_device_details.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`test/scrcpy_device_details_test.dart`、`example/integration_test/device_details_test.dart`、`docs/reports/p4-device-details.md`
  - 备注：公开 `getDeviceDetails()` API，并行读取 getprop、wm、battery、df 和 uptime，各查询组独立容错。Demo 显示基础信息及不可用字段提示；23127PN0CC USB 真机所有字段读取成功。

- [x] **P4-06 文件管理基础能力**
  - 完成判定：支持浏览、push、pull、新建目录、重命名和删除，长任务可取消；删除/覆盖明确确认目标。
  - 验证证据：含空格、中文和特殊字符路径测试，以及失败/取消测试。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_file_manager.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`example/integration_test/file_manager_test.dart`、`docs/reports/p4-file-management.md`
  - 备注：公开文件管理器支持浏览、push、pull、新建目录、重命名和删除，所有操作接受取消令牌；拒绝删除根目录，默认拒绝覆盖。Demo 提供浏览页面、任务取消和明确目标确认。真机特殊字符路径闭环通过。

- [x] **P4-07 设备运行状态**
  - 完成判定：展示电池、温度、CPU、内存、存储、网络和前台应用，并限制轮询频率。
  - 验证证据：解析测试、不同 Android 版本的缺失字段处理和轮询负载记录。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_device_status.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`test/scrcpy_device_status_test.dart`、`example/integration_test/device_status_test.dart`、`docs/reports/p4-device-status.md`
  - 备注：公开状态监视器默认 5 秒轮询且强制最短 2 秒，同一时刻只执行一轮采集。CPU 使用相邻样本差分，并采集前台应用 PID、CPU、PSS、RSS；设备支持时显示应用 GPU 忙碌率/GPU 内存以及驱动级整机 GPU/频率/来源。其余查询独立容错。Demo 可选 2/5/10/30 秒并随页面生命周期自动启动/关闭。Android 16 真机全部采集组通过。

- [x] **P4-08 批量安装/卸载应用**
  - 完成判定：支持选择多台设备安装 APK、卸载包名；操作前确认目标和参数，限制并发，可取消，并显示逐设备结果。
  - 验证证据：部分成功、超时、取消、设备中途断开的集成测试。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_batch.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`test/scrcpy_batch_test.dart`、`example/test/widget_test.dart`、`example/integration_test/batch_scheduler_test.dart`、`docs/reports/p4-batch-packages.md`
  - 备注：通用调度器支持并发限制、逐项超时、全局取消、可配置重试及逐设备快照；产品 API 只封装批量安装/卸载，不提供任意 shell 群发。Demo 具备设备多选、参数预览确认和逐项结果。只读真机故障隔离通过；因无专用测试 APK，未擅自变更真机已有应用。

## P5：应用、多显示、音频与设备墙（预计 15–25 天）

阶段策略：先稳定“一个设备上的多个独立内容 Session”，再扩展到“多个设备的设备墙”。应用、多显示、动态尺寸和音频会改变 Session 协议与生命周期，必须在响应式设备墙之前完成。

阶段完成判定：支持从应用列表选择应用并在主屏或虚拟屏启动；同一设备可同时运行两个独立应用窗口；聚焦窗口可播放音频；4 台设备同时稳定运行且单台失败不影响其他会话。

### P5-A：应用与显示源

- [x] **P5-00 ADB 高层能力归位**
  - 完成判定：设备发现/连接、应用、文件、详情、状态和批量能力只由 `adb_client` 公开；`scrcpy_flutter` 单向依赖 ADB，不保留 `Scrcpy*` 兼容接口或 ADB 代理方法。
  - 验证证据：两个包分别测试和静态检查通过；ADB 包源码不依赖 scrcpy；应用列表与启停真机回归通过。
  - 完成日期：2026-09-02
  - 提交/文件：`packages/adb_client/lib/src/adb_toolkit.dart`、`packages/adb_client/lib/src/adb_application.dart`、`packages/adb_client/lib/src/adb_device_*.dart`、`packages/adb_client/lib/src/adb_file_manager.dart`、`packages/adb_client/lib/src/adb_batch.dart`、`lib/src/scrcpy_client.dart`、`docs/architecture.md`
  - 备注：ADB 应用枚举已改用 `pm`、`dumpsys` 和 `cmd package`，不再借用 scrcpy server。本地化应用标签和图标将由未来独立 ADB helper 延迟补充，不引入反向依赖。

- [x] **P5-01 设备应用清单**
  - 完成判定：插件公开 API 能列出用户/系统应用，至少包含名称、包名、版本、启用状态和应用类型；支持搜索与刷新，单条异常不导致列表失败。
  - 验证证据：解析测试、Android 版本兼容测试、真机应用列表和首屏耗时记录。
  - 备注：基础 ADB 清单允许名称回退包名；scrcpy 层已增加内置 server 本地化名称增强，真机取得 587 个包、277 个用户应用、216 个可启动应用，至少一个可启动应用名称与包名不同，总耗时约 4.5 秒。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_application.dart`、`lib/src/scrcpy_client.dart`、`example/lib/main.dart`、`test/scrcpy_application_test.dart`、`example/integration_test/application_list_test.dart`、`docs/reports/p5-application-list.md`
  - 备注：应用图标为可选延迟加载项，不阻塞首版；优先使用包名作为稳定标识。修正 `/data/app` Base64 路径分隔后，真机 ZC-3588A（Android 15）读取 140 个包（3 个用户应用）、21 个桌面入口，首次耗时 957 ms。

- [x] **P5-02 主屏应用启动/停止**
  - 完成判定：从应用列表在设备当前主屏启动应用，可选启动前 force-stop；支持停止应用并显示逐项错误。
  - 验证证据：普通 Activity、无 Launcher Activity、已运行应用和启动失败真机测试。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_application.dart`、`example/lib/main.dart`、`test/scrcpy_application_test.dart`、`example/integration_test/application_control_test.dart`、`docs/reports/p5-application-control.md`
  - 备注：该能力不创建新视频 Session，可被单设备页和批量控制复用。真机完成计算器强停后启动、前台 Activity 确认和停止，并验证无 Launcher 包的明确失败。

- [x] **P5-03 Session 显示源模型**
  - 完成判定：Session 配置明确区分主显示、已有 displayId 和新建虚拟显示；新建显示支持尺寸、DPI、系统装饰、内容关闭策略、IME 策略和启动应用参数。
  - 验证证据：参数序列化、非法组合、向后兼容及 fake connector 测试。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_display_source.dart`、`lib/src/scrcpy_session.dart`、`lib/src/scrcpy_video_connection_io.dart`、`test/scrcpy_display_source_test.dart`、`docs/reports/p5-display-source.md`
  - 备注：默认主屏不生成额外参数；已有显示使用 `display_id`；新显示统一序列化 `new_display`、DPI、系统装饰、内容关闭策略、IME、keep-active 和 flex-display。启动应用保留为控制通道参数，由 P5-04 在虚拟显示建立后发送。

- [x] **P5-04 单虚拟屏闭环**
  - 完成判定：选择应用后创建虚拟屏、获得画面、完成鼠标键盘/触摸控制，并在关闭时按策略销毁内容或迁回主屏。
  - 验证证据：`docs/reports/p5-virtual-display.md`，至少两台不同厂商/Android 版本真机。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_control_message.dart`、`lib/src/scrcpy_input.dart`、`lib/src/scrcpy_video_connection_io.dart`、`example/lib/main.dart`、`example/integration_test/virtual_display_test.dart`、`docs/reports/p5-virtual-display.md`
  - 备注：ZC-3568K（Android 11）与 Xiaomi 23127PN0CC（Android 16）均通过。两台设备都成功创建 1280×720/240 虚拟屏、通过 START_APP 启动计算器、Native Texture 出帧、发送触摸并完成停止清理；小米应用请求竖屏后视频与 Texture 正常切换为 720×1280。

- [x] **P5-05 同设备多应用窗口**
  - 完成判定：同一设备可同时运行“主屏 + 应用 1 虚拟屏 + 应用 2 虚拟屏”中的至少两个窗口；每个窗口拥有独立 SCID、Texture、控制通道、displayId、画质和生命周期。
  - 验证证据：双虚拟屏并发测试、独立输入测试和关闭其中一个不影响另一个的异常测试。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_control_message.dart`、`lib/src/scrcpy_input.dart`、`example/lib/virtual_display_workspace.dart`、`example/integration_test/multi_virtual_display_test.dart`、`docs/reports/p5-multi-virtual-display.md`
  - 备注：Demo 工作台可在同页新增、排列、聚焦、切换应用、旋转和关闭多块虚拟屏。Xiaomi Android 16 真机同时运行横屏计算器和竖屏设置，SCID/forward/Texture/控制通道互不共享；关闭计算器后设置继续出帧，最终无新增 forward 残留。根据当前“不先考虑设备性能”的决定暂不设置人为 Session 上限。

- [x] **P5-06 虚拟屏动态尺寸与应用自适应**
  - 完成判定：Flutter 窗口变化经防抖后调整虚拟屏尺寸/DPI；支持最小/最大分辨率、偶数尺寸对齐和变化阈值，应用内容跟随重排且控制坐标准确。
  - 验证证据：连续缩放 Widget/协议测试、横竖屏与三种宽高比真机测试。
  - 完成日期：2026-09-02
  - 提交/文件：`lib/src/scrcpy_adaptive_display.dart`、`lib/src/scrcpy_control_message.dart`、`lib/src/scrcpy_input.dart`、`example/lib/virtual_display_workspace.dart`、`test/scrcpy_adaptive_display_test.dart`、`example/integration_test/multi_virtual_display_test.dart`、`docs/reports/p5-adaptive-display.md`
  - 备注：已实现预览框防抖跟随、最大/最小尺寸、偶数对齐、变化阈值、自动适应开关和手工比例/横竖切换。Xiaomi Android 16 已通过 1:1、16:9、9:16、3:1 连续 resize 且另一 Session 持续出帧；Rockchip Android 11 补充通过逐比例中心触摸及双 Session 并发测试，另一屏帧数由 2 增至 19，测试结束无新增 forward 残留。

### P5-B：音频

- [ ] **P5-07 scrcpy 音频协议与传输**
  - 完成判定：Session 独立管理 video/audio/control 通道；解析音频 codec/config/packet，支持音频可选、失败降级和 require-audio 语义，不影响现有纯视频调用方。
  - 验证证据：协议分包、断流、音频不可用、Android 10/11/12+ 行为测试和真机原始包记录。
  - 完成日期：
  - 提交/文件：
  - 备注：首版优先 Opus；Android 11 启动条件及应用禁止 playback capture 必须明确提示。

- [ ] **P5-08 Windows 音频解码、播放与焦点**
  - 完成判定：Windows 低延迟播放设备音频，支持静音、音量、缓冲和延迟统计；多个窗口同时存在时默认只播放聚焦窗口，切换无明显爆音或资源泄漏。
  - 验证证据：音画延迟、焦点切换、静音、断线重连和 30 分钟真机测试。
  - 完成日期：
  - 提交/文件：
  - 备注：音频通常是设备级 playback capture，不承诺按虚拟屏或单应用隔离；设备墙默认每台设备最多一个音频焦点。

### P5-C：多 Session 与设备墙

- [ ] **P5-09 多 Session 管理器**
  - 完成判定：插件公开 API 能并发创建、查询、聚焦、停止和销毁独立 Session；支持“设备 → display/session”层级，无共享可变单例冲突，同一宿主可嵌入多个视频组件。
  - 验证证据：并发生命周期、同设备多 Session、跨设备 Session 和资源上限测试。
  - 完成日期：
  - 提交/文件：
  - 备注：统一管理视频、音频、输入、剪贴板和重连归属。

- [ ] **P5-10 响应式设备/应用网格**
  - 完成判定：网格同时容纳设备主屏和虚拟应用窗口，格子保持比例，窗口缩放不卡顿，支持聚焦、全屏和返回设备墙。
  - 验证证据：不同窗口尺寸、1/2/4/8 格 Widget 测试及人工验收。
  - 完成日期：
  - 提交/文件：
  - 备注：键盘、剪贴板和音频只归属明确聚焦的格子。

- [ ] **P5-11 会话故障隔离与虚拟屏清理**
  - 完成判定：任一设备拔出、server/编码器崩溃、音频失败或虚拟屏关闭不影响其他窗口；异常退出后不残留可清理的 display/server/forward。
  - 验证证据：跨设备及同设备多 Session 异常注入测试。
  - 完成日期：
  - 提交/文件：
  - 备注：同设备共享硬件资源失败时必须准确标记受影响 Session。

- [ ] **P5-12 可见性、聚焦与画质调度**
  - 完成判定：聚焦、普通可见和离屏三种状态具有明确的分辨率/FPS/音频策略；动态切换不会重复启动 Session 或泄漏资源。
  - 验证证据：切换前后 CPU/GPU/内存、码率、延迟和 Session 数量对比。
  - 完成日期：
  - 提交/文件：
  - 备注：与 P6 的硬解和规模压测衔接；首版允许通过重启 Session 应用画质策略。

- [ ] **P5-13 批量基础控制**
  - 完成判定：复用 P4-08 调度器，在明确选中的设备上批量发送安全导航键、启动/停止应用；具有暂停/取消和紧急停止。
  - 验证证据：四设备执行结果和单设备脱离测试。
  - 完成日期：
  - 提交/文件：
  - 备注：首版不广播密码、剪贴板和任意文本；P4-08 已完成调度、确认和逐项结果底座。

- [ ] **P5-14 归一化触摸广播验证**
  - 完成判定：在分辨率和宽高比不同的主屏/虚拟屏之间映射触摸，检测并提示不兼容目标；默认关闭并提供紧急停止。
  - 验证证据：至少三种宽高比、主屏与虚拟屏混合坐标测试。
  - 完成日期：
  - 提交/文件：
  - 备注：属于高风险交互功能，不广播键盘密码、剪贴板或任意文本。

- [ ] **P5-15 四设备稳定性验收**
  - 完成判定：4 台设备同时运行 1 小时，支持逐台/逐应用窗口控制、聚焦切换和单音频焦点；单个 Session 故障不扩散。
  - 验证证据：`docs/reports/p5-device-wall.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：长时间验收可与延期的 P4-04 集中执行，但不得在发布候选前跳过。

## P6：性能调度与压测（预计 5–10 天）

阶段完成判定：8 台达到稳定目标，并形成可复查的 16 台压力测试报告。

- [ ] **P6-01 资源指标采集**
  - 完成判定：能按 Session 和全局记录 FPS、码率、解码器、CPU、GPU、内存、线程和错误计数。
  - 验证证据：指标采集文档和样例输出。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P6-02 可见性与聚焦策略性能调优**
  - 完成判定：基于 P5-12 已实现策略，用 P6-01 指标确定聚焦、普通可见、离屏三种状态的最终分辨率/FPS/音频阈值，并证明切换无资源泄漏或持续延迟增长。
  - 验证证据：1/4/8 Session 策略切换前后的 CPU、GPU、内存、码率、延迟和恢复时间对比。
  - 完成日期：
  - 提交/文件：
  - 备注：P5-12 负责功能正确性，本项只负责用规模数据调参和确定产品默认值，避免重复实现。

- [ ] **P6-05 D3D11 硬解与零拷贝视频路径**
  - 完成判定：Windows 使用硬件解码，并通过 D3D11 共享纹理或等效路径交给 Flutter；不再为每帧执行全尺寸 CPU NV12→RGBA，且保留软件回退。
  - 验证证据：与 P1 CPU 路径对比单路及多路 CPU/GPU/内存、首帧和 P95 延迟，并覆盖驱动不支持时回退测试。
  - 完成日期：
  - 提交/文件：
  - 备注：P1 单路归一化 CPU 基线为 10.76%，该任务是 P6-03 八设备稳定验收的前置条件，除非目标硬件实测证明 CPU 路径已满足指标。

- [ ] **P6-03 八设备稳定验收**
  - 完成判定：目标硬件上 8 台运行达到约定画质、延迟和稳定性标准。
  - 验证证据：`docs/reports/p6-8-devices.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P6-04 十六设备压力测试**
  - 完成判定：无论结果成功或失败，都记录瓶颈、降级策略和可支持上限，不把压测目标自动视为产品承诺。
  - 验证证据：`docs/reports/p6-16-devices.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：

## P7：发布准备（预计 2–4 天）

阶段完成判定：新环境可按文档构建并运行示例，API、许可证、限制和升级流程完整。

- [ ] **P7-01 API 与接入文档**
  - 完成判定：包含插件依赖安装、初始化、能力查询、权限、设备发现、无 UI 用法、单/多视频组件嵌入、控制、错误处理和销毁示例。
  - 验证证据：从空白 Flutter 项目按文档接入成功。
  - 完成日期：
  - 提交/文件：
  - 备注：

## P8：移动端与 Web 可行性验证（后期独立排期）

阶段说明：P8 不阻塞 Windows 产品线，也不预先承诺交付。每个平台先完成技术原型和发布约束调查，再决定是否建立正式里程碑。

- [ ] **P8-01 抽离跨平台核心边界**
  - 完成判定：ADB transport、scrcpy 协议、会话模型、控制消息和 Flutter Widget 与 Windows 进程实现解耦，能替换 transport 和视频后端。
  - 验证证据：平台接口文档和至少一个 fake transport 测试。
  - 完成日期：
  - 提交/文件：
  - 备注：应在 Windows API 稳定后执行，避免过早抽象。

- [ ] **P8-02 Android USB Host ADB 原型**
  - 完成判定：Android Flutter 宿主能够申请 USB 权限、完成 ADB 握手、执行 shell 并传输文件，不依赖外部 `adb` 可执行文件。
  - 验证证据：至少两种 Android 宿主和两种目标设备的测试报告。
  - 完成日期：
  - 提交/文件：
  - 备注：记录 OTG、供电、Hub 和 RSA 密钥安全问题。

- [ ] **P8-03 Android 网络 ADB/配对原型**
  - 完成判定：Android 宿主支持网络连接和 Wireless Debugging 配对，凭据使用平台安全存储。
  - 验证证据：配对、重连、错误码和密钥迁移测试。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P8-04 Android scrcpy 视频与控制原型**
  - 完成判定：通过 MediaCodec 显示目标设备画面并完成基础触摸控制，持续运行 30 分钟。
  - 验证证据：`docs/reports/p8-android-host.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：先单设备，不承诺设备墙。

- [ ] **P8-05 iOS/iPadOS 可行性调查**
  - 完成判定：明确网络 ADB、USB 配件访问、后台运行、密钥存储、App Store/企业分发限制，并通过至少一个真机最小原型或给出不可行结论。
  - 验证证据：`docs/reports/p8-ios-feasibility.md`，包含引用的 Apple 官方资料。
  - 完成日期：
  - 提交/文件：
  - 备注：允许结论为“不继续实现”。

- [ ] **P8-06 WebUSB ADB 原型**
  - 完成判定：在受支持的 Chromium 浏览器和 HTTPS 环境中完成设备授权、ADB 握手、shell 和 server 推送。
  - 验证证据：浏览器/系统支持矩阵和 `docs/reports/p8-webusb.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：优先评估复用 Tango ADB，避免自行重写全部 Web ADB 协议。

- [ ] **P8-07 WebCodecs scrcpy 视频与控制原型**
  - 完成判定：浏览器以 WebCodecs 解码 H.264，Canvas/Flutter Web 显示画面并发送基础控制，持续运行 30 分钟。
  - 验证证据：首帧、延迟、CPU/GPU 和浏览器兼容报告。
  - 完成日期：
  - 提交/文件：
  - 备注：Safari/Firefox 不作为默认承诺。

- [ ] **P8-08 Web 代理/网关路线评估**
  - 完成判定：评估“Web UI + Windows/Linux 本地代理或远程设备网关”，明确认证、加密、设备隔离、延迟和部署成本。
  - 验证证据：`docs/reports/p8-web-gateway.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：该路线可覆盖不支持 WebUSB 的浏览器，但引入服务端安全边界。

- [ ] **P8-09 平台继续/终止决策**
  - 完成判定：分别对 Android、HarmonyOS/OpenHarmony、iOS、Web 给出继续、有限支持或终止结论，并据实建立新里程碑，不能用一个平台成功推定其他平台可行。
  - 验证证据：更新功能范围、架构文档和决策日志。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P8-10 HarmonyOS/OpenHarmony Flutter 工具链验证**
  - 完成判定：建立可复现的 Flutter OHOS 构建环境，示例应用可在目标鸿蒙真机运行，平台插件和 FFI 能正常工作。
  - 验证证据：工具链版本、构建步骤、真机信息脱敏记录和最小插件测试。
  - 完成日期：
  - 提交/文件：
  - 备注：只验证鸿蒙作为控制端，不涉及鸿蒙被控。

- [ ] **P8-11 鸿蒙网络 ADB 与配对原型**
  - 完成判定：鸿蒙宿主通过 TCP socket 完成 Android 网络 ADB、Wireless Debugging 配对、shell 和 server 推送；密钥安全存储。
  - 验证证据：成功、错误配对码、重连、网络切换和后台恢复测试。
  - 完成日期：
  - 提交/文件：
  - 备注：网络路线为首选。

- [ ] **P8-12 鸿蒙 USB ADB 权限与传输验证**
  - 完成判定：确认普通发行应用能否获得所需 USB 能力，并在允许时完成 Android ADB 握手、bulk transfer 和 shell；不允许时形成明确终止结论。
  - 验证证据：`docs/reports/p8-harmony-usb.md`，引用官方权限和发行文档。
  - 完成日期：
  - 提交/文件：
  - 备注：允许最终仅支持网络 ADB。

- [ ] **P8-13 鸿蒙 scrcpy 视频与控制原型**
  - 完成判定：鸿蒙宿主使用平台原生硬解后端显示 Android 画面，并完成基础模拟触摸，持续运行 30 分钟。
  - 验证证据：`docs/reports/p8-harmony-host.md`，记录解码器、延迟和资源占用。
  - 完成日期：
  - 提交/文件：
  - 备注：被控端必须是 Android。

## P7：发布准备（续）

- [ ] **P7-02 第三方许可证与发行检查**
  - 完成判定：scrcpy、ADB、平台视频依赖及二进制分发条款清晰，NOTICE/许可证文件齐全。
  - 验证证据：第三方组件清单和人工审核记录。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P7-03 干净环境构建验证**
  - 完成判定：新 Windows 环境创建一个仓库外的干净 Flutter 应用，通过 path 或发布包依赖插件，按文档完成构建和真机运行；不复制 example 源码。
  - 验证证据：`docs/reports/p7-clean-build.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P7-04 发布候选验收**
  - 完成判定：所有承诺平台和功能通过回归，已知限制写入 CHANGELOG/README，版本号和发布包一致。
  - 验证证据：发布检查表及构建产物校验值。
  - 完成日期：
  - 提交/文件：
  - 备注：

---

## 后续功能池（尚未排期）

- 聚焦设备音频已纳入 P5-07/P5-08，不在功能池重复排期。
- [ ] 截图。
- [ ] 屏幕录制。
- 应用列表与启动已纳入 P5-01/P5-02；完整权限和进程管理保留后续排期。
- [ ] 日志查看和性能分析。
- [ ] 相机镜像、游戏手柄、UHID/AOA/OTG 等高级 scrcpy 能力。
- [ ] 受控任务模板和定时自动化。
- [ ] Linux 主机支持。
- [ ] macOS 主机支持。
- [ ] Windows/Linux/macOS 远程设备网关。

## 变更/决策日志

按时间倒序追加，已经发生的决定不得删除。

| 日期 | 决策/变更 | 原因 | 影响 |
| --- | --- | --- | --- |
| 2026-09-02 | 将应用列表/启动、虚拟屏、多应用窗口、动态尺寸和音频前置到设备墙之前 | 这些能力会改变 Session 的显示源、通道和生命周期；先做网格会导致底层返工 | P5 重排为应用与显示源、音频、多 Session 与设备墙三段；原未开始的 P5-01～P5-09 重新编号为 P5-01～P5-15 |
| 2026-09-02 | 音频采用聚焦策略且不承诺按虚拟屏/单应用隔离 | scrcpy playback capture 通常是设备级输出，多窗口同时播放会混乱且增加资源占用 | 设备墙默认每台设备只有一个音频焦点，音频失败不得中断视频 |
| 2026-09-02 | P4-08 已完成安全批量调度底座 | 安装/卸载已覆盖并发、超时、取消、重试和逐项结果 | 原 P5 批量框架不再重复实现，P5-13 直接复用 |
| 2026-08-31 | 首发平台暂定 Windows | 产品目标首先是桌面设备墙 | 其他平台保留模板但不承诺支持 |
| 2026-08-31 | 暂定 scrcpy 4.1 | 固定协议版本，避免客户端和 server 不匹配 | 升级必须经过协议及真机回归 |
| 2026-08-31 | 稳定目标 8 台、压力测试 16 台 | 先通过实测确定产品上限 | 16 台不是预先承诺的稳定能力 |
| 2026-08-31 | 首版闭环加入 USB/网络/配对码连接、画面、画质和模拟触摸 | 覆盖实际设备接入和控制需求 | P2、P3 增加连接与控制任务 |
| 2026-08-31 | 设备详情、文件管理、运行状态列为 S1 | 有价值但不阻塞画面与控制主链路 | 在单设备稳定后逐步实现 |
| 2026-08-31 | 批量安装/卸载前置，设备墙和触摸广播后置 | 先交付风险较低且实用的批量 ADB 能力 | 建立统一批处理安全框架 |
| 2026-08-31 | 应用多开使用 scrcpy virtual display 做 S2 验证 | 能力受 Android 版本和厂商实现影响 | 先做兼容矩阵，不作为首版承诺 |
| 2026-08-31 | 后期增加 Android、iOS 和 Web 可行性门 | Android 与 Chromium Web 有技术路径，iOS 风险较高 | 新增 P8，各平台独立作继续/终止决策 |
| 2026-08-31 | 增加鸿蒙宿主控制 Android | HarmonyOS 具备网络能力，USB 权限和原生视频后端仍需验证 | P8 新增工具链、网络、USB、视频控制四项；不支持鸿蒙被控 |
| 2026-08-31 | 明确项目以可嵌入 Flutter 插件交付 | 后期需要嵌入其他应用，不能先做成绑定业务的独立程序 | 插件优先成为 P0 强制约束，新增边界、多实例和资源打包验收 |
| 2026-08-31 | ADB 抽为仓库内独立模块/package，暂不拆独立仓库 | ADB 被设备管理、批量任务、scrcpy 和未来多平台共同使用，但过早独立发布会增加维护成本 | scrcpy 只依赖 ADB 接口；Windows 先实现 process 后端，移动/Web 后加 transport |
| 2026-08-31 | `scrcpy_video_view 0.0.1` 仅作参考 | 仅支持 macOS，逐帧经过 MethodChannel，且协议头假设与 4.1 不一致 | 借鉴状态机、错误模型和生命周期测试，不直接依赖 |
| 2026-08-31 | P0 实现从独立 ADB package 与 process 后端开始 | ADB 是连接、设备管理、批量任务和 scrcpy 会话的共同底座 | 根插件通过注入的 `AdbClient` 使用能力；平台后端可替换 |
| 2026-08-31 | Windows 插件内置官方 Platform-Tools ADB | 最终用户不应被要求安装 Android SDK 或配置 PATH | 默认从应用目录加载；保留明确路径覆盖；二进制、DLL、NOTICE 和 SHA-256 一并管理 |
| 2026-08-31 | 每个可验证增量同步维护 example | 方便在真机和桌面环境尽早发现集成问题 | 首个 Demo 已展示内置 ADB 信息、刷新状态和脱敏设备列表；example 只使用插件公开 API |
| 2026-08-31 | 暂不引入 `flutter_adb` | 其纯 Dart 实现适合网络 ADB，但当前缺少 Windows 首版依赖的 USB、完整 sync 和 forward 能力 | 保持官方内置 ADB process 后端；统一接口继续允许后期增加 wire transport |

## 交接记录

每次责任人或开发阶段发生切换时追加一条：

| 日期 | 交接人 | 接手人 | 已完成到 | 下一步 | 已知问题/风险 |
| --- | --- | --- | --- | --- | --- |
| 2026-08-31 | 初始规划 | 待定 | 架构、里程碑和逐项清单 | P0-01 环境健康检查 | Flutter/ADB 命令曾阻塞，需确认进程来源 |

