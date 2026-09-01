# 可执行开发计划与交接清单

更新于 2026-09-01。

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

- 当前阶段：P1 视频技术验证。
- 当前状态：P0 工程基线和 scrcpy 4.1 视频拆包已完成；Windows Media Foundation 后端已通过真机实际解码帧计数测试。
- 下一项：用重新构建的 Demo 视觉确认实时刷新和首屏耗时，再实现积压时保留最新可解帧。
- 当前阻塞：无协议或解码阻塞；仍需视觉验收和性能数据，不能仅凭帧计数勾选 P1-05。
- 已选基线：Windows、scrcpy 4.1、平台原生解码、网络/USB ADB、H.264、首版无音频。
- 首版功能闭环：USB/网络/配对码连接，查看当前画面，画质配置，scrcpy 基础控制和模拟触摸。
- 交付形态：从 P0 起按可嵌入 Flutter 插件实现；example 只消费插件公开 API，不承载核心逻辑。
- 早期增强：设备详情、文件管理、运行状态，以及安装/卸载等批量 ADB 操作。
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

- [ ] **P1-02 Flutter 显示真机首帧**
  - 完成判定：Flutter Widget 显示正确方向、比例和内容的第一帧，并进入稳定播放状态。
  - 验证证据：记录首帧耗时、解码器、分辨率、FPS、CPU/GPU/内存基线。
  - 完成日期：
  - 提交/文件：
  - 备注：进行中。`ScrcpyVideoConnection → Media Foundation → Flutter Texture` 已在真机出首帧；Demo 设备详情页支持启动/停止画面。尚缺完整性能基线和连续播放记录。

- [ ] **P1-03 帧级原生低延迟视频后端**
  - 交付物：保留 scrcpy codec/session/frame metadata 的 Dart 拆包器；统一原生解码后端接口；Windows Media Foundation 解码与最新帧 Flutter Texture。
  - 验收：首屏延迟和触摸到画面延迟均可测量；连续操作画面实时刷新；解码积压时只保留最新可解帧；不在 Dart 层逐帧复制 RGBA。
  - 参考：`scrcpy_video_view 0.0.1` 的 macOS 实现使用 scrcpy 12 字节帧头、VideoToolbox、单一 latest pixel buffer 和 `textureFrameAvailable()`；其代码仅支持 macOS，不能直接作为 Windows 依赖。
  - 进度（2026-09-01）：已按 scrcpy 4.1 修正 codec/session/frame 拆包。Windows MF 后端设置 `MF_LOW_LATENCY` 后严格测试通过；已修复 NV12 stride 和 RGBA 通道顺序。NV12→RGBA 已移到独立线程，转换队列只保留最新解码帧。Demo 已支持最大尺寸、FPS、码率选择，并每秒显示实际 FPS、累计显示帧、编码包和接收流量；真机集成测试 `frames=11 / inputs=11` 通过。尚需测量端到端延迟、旋转和 D3D11 零拷贝后勾选。

- [ ] **P1-04 验证旋转和动态分辨率**
  - 完成判定：横竖屏切换不会永久黑屏或崩溃；宽高比和 texture 生命周期正确。
  - 验证证据：至少连续旋转 20 次，记录是否重建 Player/texture。
  - 完成日期：
  - 提交/文件：
  - 备注：2026-09-01 已将 scrcpy 4.1 的重复 session 尺寸事件公开到视频连接；控制器在尺寸变化时暂停包消费、串行释放旧 Texture、按新宽高创建解码器并恢复流。自动化测试覆盖 1080×1920 → 1920×1080、旧 Texture 释放和停止清理。尚需真机连续旋转 20 次后勾选。

- [ ] **P1-05 视频稳定性验收**
  - 完成判定：连续播放 30 分钟，无持续延迟增长、资源明显泄漏或不可恢复错误。
  - 验证证据：`docs/reports/p1-video-spike.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：

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
  - 备注：已实现 `ScrcpyClient.pair`、mDNS pairing/connect 服务发现与 Demo 验证码配对表单；选择配对服务会自动匹配同主机变化后的最新连接端口。配对码输入隐藏，ADB 诊断参数已脱敏且不持久化。自动化覆盖成功、错误码、过期、取消、IPv4/IPv6 和端口变化；2026-09-01 用户确认手工真机验证通过。

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

- [ ] **P3-03 坐标映射**
  - 完成判定：正确处理 contain/cover、黑边、裁剪、DPI、窗口缩放、横竖屏和动态视频尺寸。
  - 验证证据：纯函数单元测试覆盖边界和四角坐标。
  - 完成日期：
  - 提交/文件：
  - 备注：2026-09-01 已实现 `BoxFit.contain/cover`、居中对齐、黑边过滤和 cover 源裁剪补偿；Demo 随动态视频尺寸更新映射。纯函数测试已覆盖 contain 黑边/边界和 cover 裁剪，尚需补齐四角、非居中 alignment 与真机旋转验证后勾选。

- [ ] **P3-04 基础导航与输入**
  - 完成判定：点击、长按、拖动/滑动、滚轮、Back、Home、Recent Apps、Power、Wake、音量、Enter、Delete 和基础键盘输入可用。
  - 验证证据：真机操作清单逐项通过。
  - 完成日期：
  - 提交/文件：
  - 备注：2026-09-01 真机双 socket 集成测试通过，control 通道成功发送 CANCEL 消息且视频持续解码 `frames=11 / inputs=11`。Demo 已可尝试点击、拖动、滚轮和键盘控制。坐标映射已支持 contain/cover 和黑边过滤，仍需按本项清单逐项真机验收。

- [ ] **P3-06 多指与手势模拟**
  - 完成判定：正确维护多个 pointer ID，支持双指缩放等基础多指事件，取消/抬起不会遗留触点。
  - 验证证据：序列化 fixture、Widget 事件测试和真机手势测试。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P3-07 剪贴板与文本输入**
  - 完成判定：支持基础文本注入和可开关的双向剪贴板同步，避免自身写入导致循环同步。
  - 验证证据：中英文、换行、特殊字符和循环抑制测试。
  - 完成日期：
  - 提交/文件：
  - 备注：密码及敏感剪贴板不进入日志。

- [ ] **P3-08 视频画质配置**
  - 完成判定：API/UI 支持最大尺寸、最大 FPS、视频码率、H.264/H.265/AV1 能力选择及编码器选择；不支持时明确回退或报错。
  - 验证证据：启动参数测试和至少两档画质的真机指标对比。
  - 完成日期：
  - 提交/文件：
  - 备注：首版默认仍为 H.264。

- [ ] **P3-05 控制稳定性验收**
  - 完成判定：横竖屏各连续操作 10 分钟，无坐标漂移、卡死和控制协议错位。
  - 验证证据：`docs/reports/p3-control.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：

## P4：单设备稳定版与 S1 管理能力（核心 4–6 天，S1 增强 6–12 天）

阶段完成判定：单设备连续运行 2 小时，拔插、断流、旋转和应用退出均能恢复或明确失败。

- [ ] **P4-01 USB 热插拔检测**
  - 完成判定：设备加入、离开、unauthorized/offline 状态能更新到 Flutter。
  - 验证证据：真机拔插测试记录。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P4-02 断线与重连策略**
  - 完成判定：区分用户停止与意外断线；重连有次数、退避和取消机制，不产生重复会话。
  - 验证证据：异常注入和恢复日志。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P4-03 示例应用单设备页面**
  - 完成判定：仅使用插件公开 API，具备设备选择、启动/停止、画面、基础控制、状态、错误和诊断信息；example 内无协议、ADB 或解码核心逻辑。
  - 验证证据：example Windows 构建与人工验收。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P4-04 两小时稳定性验收**
  - 完成判定：连续显示和间歇控制 2 小时，无崩溃、显著泄漏或持续延迟增长。
  - 验证证据：`docs/reports/p4-single-device.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P4-05 设备基础详情**
  - 完成判定：提供品牌、型号、Android/SDK、ABI、屏幕、密度、连接类型、电池、存储和 uptime；单字段失败不导致整页失败。
  - 验证证据：数据来源文档、解析测试和真机页面。
  - 完成日期：
  - 提交/文件：
  - 备注：S1，可在单设备控制稳定后完成。

- [ ] **P4-06 文件管理基础能力**
  - 完成判定：支持浏览、push、pull、新建目录、重命名和删除，长任务可取消；删除/覆盖明确确认目标。
  - 验证证据：含空格、中文和特殊字符路径测试，以及失败/取消测试。
  - 完成日期：
  - 提交/文件：
  - 备注：S1，可后置，不阻塞设备墙视频原型。

- [ ] **P4-07 设备运行状态**
  - 完成判定：展示电池、温度、CPU、内存、存储、网络和前台应用，并限制轮询频率。
  - 验证证据：解析测试、不同 Android 版本的缺失字段处理和轮询负载记录。
  - 完成日期：
  - 提交/文件：
  - 备注：S1，可后置。

- [ ] **P4-08 批量安装/卸载应用**
  - 完成判定：支持选择多台设备安装 APK、卸载包名；操作前确认目标和参数，限制并发，可取消，并显示逐设备结果。
  - 验证证据：部分成功、超时、取消、设备中途断开的集成测试。
  - 完成日期：
  - 提交/文件：
  - 备注：作为首批批量 ADB 能力，不提供任意 shell 群发。

## P5：设备墙、批量控制与多开原型（预计 8–14 天）

阶段完成判定：4 台设备同时稳定运行，单台失败不会中断其他会话。

- [ ] **P5-01 多 Session 管理器**
  - 完成判定：插件公开 API 能够并发创建、查询、停止和销毁独立 Session，无共享可变单例资源冲突，同一宿主可嵌入多个视频组件。
  - 验证证据：并发生命周期测试。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P5-02 响应式设备网格**
  - 完成判定：设备格子保持比例，窗口缩放不卡顿，支持聚焦/返回设备墙。
  - 验证证据：不同窗口尺寸的 Widget/人工测试。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P5-03 会话故障隔离**
  - 完成判定：任意一台拔出、server 崩溃或解码失败不影响其他 Player 和控制连接。
  - 验证证据：四设备异常注入测试。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P5-04 四设备稳定性验收**
  - 完成判定：4 台设备同时运行 1 小时，支持逐台控制和聚焦切换。
  - 验证证据：`docs/reports/p5-device-wall.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P5-05 安全的批量 ADB 操作框架**
  - 完成判定：统一实现目标选择、参数预览、并发限制、超时、取消、重试和逐设备结果，安装/卸载基于该框架运行。
  - 验证证据：调度器单元测试及混合成功/失败集成测试。
  - 完成日期：
  - 提交/文件：
  - 备注：破坏性操作必须额外确认。

- [ ] **P5-06 批量基础控制**
  - 完成判定：支持在明确选中的设备上批量发送安全导航键、启动/停止应用；具有暂停和紧急停止。
  - 验证证据：四设备执行结果和单设备脱离测试。
  - 完成日期：
  - 提交/文件：
  - 备注：首版不广播密码、剪贴板和任意文本。

- [ ] **P5-07 归一化触摸广播验证**
  - 完成判定：在分辨率和宽高比不同的设备间映射触摸，检测并提示不兼容设备；默认关闭。
  - 验证证据：至少三种宽高比的坐标与真机测试。
  - 完成日期：
  - 提交/文件：
  - 备注：属于高风险交互功能，必须提供紧急停止。

- [ ] **P5-08 应用多开/虚拟显示技术验证**
  - 完成判定：使用 scrcpy new/virtual display 启动指定应用，独立维护画面、控制坐标和生命周期，并记录兼容设备矩阵。
  - 验证证据：`docs/reports/p5-virtual-display.md`。
  - 完成日期：
  - 提交/文件：
  - 备注：S2，不阻塞基础设备墙；无法保证所有厂商设备支持。

- [ ] **P5-09 多开页面自适应布局**
  - 完成判定：同一设备的多个 display/session 可自动布局、聚焦、关闭，窗口缩放时保持比例。
  - 验证证据：Widget 测试和至少一个支持虚拟显示的真机演示。
  - 完成日期：
  - 提交/文件：
  - 备注：依赖 P5-08。

## P6：性能调度与压测（预计 5–10 天）

阶段完成判定：8 台达到稳定目标，并形成可复查的 16 台压力测试报告。

- [ ] **P6-01 资源指标采集**
  - 完成判定：能按 Session 和全局记录 FPS、码率、解码器、CPU、GPU、内存、线程和错误计数。
  - 验证证据：指标采集文档和样例输出。
  - 完成日期：
  - 提交/文件：
  - 备注：

- [ ] **P6-02 可见性与聚焦调度**
  - 完成判定：聚焦、普通可见、离屏三种状态具有明确分辨率/FPS策略，切换不会泄漏资源。
  - 验证证据：策略切换前后指标对比。
  - 完成日期：
  - 提交/文件：
  - 备注：

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

- [ ] 聚焦设备音频。
- [ ] 截图。
- [ ] 屏幕录制。
- [ ] 完整应用列表、应用详情、权限和进程管理。
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
